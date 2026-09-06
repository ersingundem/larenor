import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:larenor/features/home_resources/domain/home_resource_mutations.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_resource_admin_contract_fixture.dart';

typedef _Reply = (int, Map<String, dynamic>?);

/// Explicit metadata-only fixture, never a home/provider adapter. Authorization
/// belongs to SyntheticCoreAccount; scope is fixed by the actual HTTP contract.
class SyntheticCoreResourceAdmin {
  SyntheticCoreResourceAdmin();
  /// Real contract state after an ACL change; there is no fixture ACL endpoint.
  SyntheticCoreResourceAdmin.beforeUpdate() {
    _records.add(_clone(_contract['beforeUpdate']['record'] as Map<String, dynamic>));
    _sequence = 1;
  }
  static final Map<String, dynamic> _contract = jsonDecode(homeResourceAdminContractFixture) as Map<String, dynamic>;
  final _records = <Map<String, dynamic>>[];
  final mutations = <String>[];
  int reads = 0;
  int _sequence = 0;
  /// Suspend one successful response after its in-memory effect; timeout never
  /// rolls back/retries. Tests release the gate before closing their server.
  Completer<void>? replyGate;
  List<Map<String, dynamic>> get records => List.unmodifiable(_records.map(_clone));
  static Map<String, dynamic> _clone(Map<String, dynamic> value) => jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  static _Reply _error(int status, String code) => (status, {'error': {'code': code}});
  void close() { final gate=replyGate; if(gate!=null && !gate.isCompleted) gate.complete(); }

  Future<_Reply> handle(HttpRequest request, String coreId, String homeId, String userId) async {
    if(coreId!=_contract['context']['coreId'] || homeId!=_contract['context']['homeId']) return _error(404,'not_found');
    final readBase='/api/v1/home-resources/$coreId/$homeId';
    final writeBase='/api/v1/admin/home-resources/$coreId/$homeId';
    final path=request.uri.path;
    final readTarget=path==readBase || path.startsWith('$readBase/');
    final writeTarget=path==writeBase || path.startsWith('$writeBase/');
    if(!readTarget && !writeTarget) return _error(404,'not_found');
    final read=request.method=='GET' && readTarget;
    final write={'POST','PATCH','DELETE'}.contains(request.method) && writeTarget;
    if(!read && !write) return _error(403,'forbidden');
    final base=read?readBase:writeBase;
    final id=path==base?null:path.substring(base.length+1);
    if(id!=null && !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) return _error(404,'not_found');
    if(write && (request.method=='POST')!=(id==null)) return _error(404,'not_found');
    final query=request.uri.queryParametersAll;
    if(query.values.any((values)=>values.length!=1)) return _error(400,'invalid_request');
    final bytes=<int>[];
    try {
      await for(final chunk in request.timeout(const Duration(seconds:2))) {
        if(bytes.length+chunk.length>4096) return _error(413,'invalid_request');
        bytes.addAll(chunk);
      }
    } on TimeoutException { return _error(400,'invalid_request'); }
    if(read) {
      if(bytes.isNotEmpty) return _error(400,'invalid_request');
      return _read(coreId,homeId,userId,id,query);
    }
    Map<String,dynamic>? body;
    if(request.method=='DELETE') {
      if(bytes.isNotEmpty || query.keys.toSet().difference({'expectedRevision','expectedAclRevision'}).isNotEmpty || query.length!=2) return _error(400,'invalid_request');
    } else {
      if(request.uri.hasQuery) return _error(400,'invalid_request');
      try {
        if(request.headers.contentType?.mimeType!='application/json') return _error(400,'invalid_request');
        body=_body(utf8.decode(bytes));
      } on FormatException { return _error(400,'invalid_request'); }
      if(body==null) return _error(400,'invalid_request');
    }
    final reply=_write(request.method,id,query,body);
    if(reply.$1<300) {
      mutations.add(request.method);
      final gate=replyGate;
      if(gate!=null) {
        try { await gate.future.timeout(const Duration(seconds:3)); }
        on TimeoutException { return _error(503,'service_unavailable'); }
        finally { if(identical(replyGate,gate)) replyGate=null; }
      }
    }
    return reply;
  }

  _Reply _read(String coreId,String homeId,String userId,String? id,Map<String,List<String>> query) {
    if(id!=null) {
      if(query.isNotEmpty) return _error(400,'invalid_request');
      final entry=_records.where((r)=>r['ref']['id']==id).firstOrNull;
      if(entry==null) return _error(404,'not_found');
      reads++;return(200,{'record':_clone(entry)});
    }
    if(query.keys.any((key)=>!{'limit','after','expectedSnapshot'}.contains(key))) return _error(400,'invalid_request');
    final rawLimit=query['limit']?.single??'25';final limit=int.tryParse(rawLimit);
    final after=query['after']?.single;final expected=query['expectedSnapshot']?.single;
    if(limit==null || !RegExp(r'^[1-9][0-9]{0,2}$').hasMatch(rawLimit) || limit>100 ||
      (after!=null && (!RegExp(r'^[0-9a-f]{32}$').hasMatch(after) || expected==null)) ||
      (expected!=null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(expected))) return _error(400,'invalid_request');
    final sorted=_records.toList()..sort((a,b)=>(a['ref']['id'] as String).compareTo(b['ref']['id'] as String));
    // Synthetic scoped snapshot, not a production HMAC or authorization grant.
    final snapshot=sha256.convert(utf8.encode(jsonEncode(['admin-fixture-v1',coreId,homeId,userId,sorted]))).toString();
    if(expected!=null && expected!=snapshot) return _error(409,'revision_conflict');
    if(after!=null && !sorted.any((r)=>r['ref']['id']==after)) return _error(404,'not_found');
    final rest=sorted.where((r)=>after==null || (r['ref']['id'] as String).compareTo(after)>0).toList();
    final page=rest.take(limit).map(_clone).toList();reads++;
    return(200,{'scope':_contract['context'],'entries':page,'snapshot':snapshot,'nextAfter':rest.length>limit?page.last['ref']['id']:null});
  }
  static int? _revision(Object? value) => value is int && value>=1 && value<=9223372036854775807 ? value:null;
  static int? _queryRevision(String? value) => value!=null && RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(value) ? _revision(int.tryParse(value)):null;
  _Reply _write(String method,String? id,Map<String,List<String>> query,Map<String,dynamic>? body) {
    if(method!='DELETE') {
      final keys=method=='POST'?{'kind','label','order'}:{'expectedRevision','expectedAclRevision','label','order'};
      if(body!.length!=keys.length || !keys.every(body.containsKey) || body['label'] is! String || body['order'] is! int) return _error(400,'invalid_request');
    }
    HomeResourceMetadata? metadata;
    if(body!=null) {
      try { metadata=HomeResourceMetadata(label:body['label'] as String,order:body['order'] as int); }
      on LarenorServerException { return _error(400,'invalid_request'); }
    }
    if(method=='POST') {
      if(!{'room','resource'}.contains(body!['kind'])) return _error(400,'invalid_request');
      if(_records.length>=32) return _error(409,'resource_limit');
      _sequence++;
      final identity=_sequence<=2 ? '${_sequence}'*32 : _sequence.toRadixString(16).padLeft(32,'0');
      final record=<String,dynamic>{'ref':{..._contract['context'] as Map,'id':identity,'kind':body['kind']},...metadata!.toJson(),'revision':1,'aclRevision':1,'permissions':{'read':true,'write':true}};
      _records.add(record);return(201,{'record':_clone(record)});
    }
    final revision=method=='DELETE'?_queryRevision(query['expectedRevision']?.single):_revision(body!['expectedRevision']);
    final acl=method=='DELETE'?_queryRevision(query['expectedAclRevision']?.single):_revision(body!['expectedAclRevision']);
    if(revision==null || acl==null) return _error(400,'invalid_request');
    final index=_records.indexWhere((r)=>r['ref']['id']==id);
    if(index<0) return _error(404,'not_found');
    final old=_records[index];
    if(revision!=old['revision'] || acl!=old['aclRevision']) return _error(409,'revision_conflict');
    if(method=='DELETE') { _records.removeAt(index);return(204,null); }
    final changed=old['label']!=metadata!.label || old['order']!=metadata.order;
    if(changed && revision==9223372036854775807) return _error(409,'revision_conflict');
    final record={...old,...metadata.toJson(),'revision':revision+(changed?1:0)};
    _records[index]=record;return(200,{'record':_clone(record)});
  }
  /// Scan complete flat JSON string tokens before ':' so jsonDecode cannot
  /// silently accept duplicate keys, including Unicode-escaped equal keys.
  static Map<String,dynamic>? _body(String text) {
    final value=jsonDecode(text);
    if(value is! Map<String,dynamic> || value.values.any((v)=>v is Map || v is List)) return null;
    final keys=<String>{};var index=0;
    while(index<text.length) {
      if(text.codeUnitAt(index)!=34) { index++;continue; }
      final start=index++;
      while(index<text.length) {
        final char=text.codeUnitAt(index++);
        if(char==92) { index++;continue; }
        if(char==34) break;
      }
      final end=index;
      while(index<text.length && const [9,10,13,32].contains(text.codeUnitAt(index))) { index++; }
      if(index<text.length && text[index]==':') {
        final key=jsonDecode(text.substring(start,end)) as String;
        if(!keys.add(key)) return null;
      }
    }
    return value;
  }
}
