import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'home_resource_grants_contract_fixture.dart';

typedef GrantsReply = (int, Map<String,dynamic>?);

/// Opt-in, fixed-record ACL fixture. It has no provider or metadata mutation API.
class SyntheticCoreResourceGrants {
  static final Map<String,dynamic> _contract=jsonDecode(homeResourceGrantsContractFixture) as Map<String,dynamic>;
  final Map<String,Map<String,bool>> _grants={};
  int aclRevision=1,usersReads=0,grantReads=0,recordReads=0,putRequests=0;
  bool failNextPutReply=false;
  Completer<void>? replyGate;
  final List<String> mutations=[];
  Map<String,dynamic> get target => jsonDecode(jsonEncode(_contract['target'])) as Map<String,dynamic>;
  Map<String,Map<String,bool>> get grants => Map.unmodifiable(_grants.map((id,value)=>MapEntry(id,Map.unmodifiable(value))));
  List<Map<String,Object>> get users=>[
    for(final id in ['2','3','9']) {
      'id':id*32,'username':id=='9'?'fixture-core-user':'person_$id','role':id=='9'?'admin':'member',
      'disabled':false,'mustChangePassword':false,'revision':1,'createdAt':'2026-09-06T00:00:00Z',
    },
  ];
  static GrantsReply error(int status,String code) =>(status,{'error':{'code':code,'message':switch(code){
    'not_found'=>'The requested resource was not found.',
    'forbidden'=>'This account cannot perform that action.',
    'revision_conflict'=>'The saved record has changed. Read it again.',
    _=>'The request is invalid.',
  }}});
  void close(){final gate=replyGate;if(gate!=null&&!gate.isCompleted)gate.complete();}

  Future<GrantsReply> handle(HttpRequest request,String coreId,String homeId,String userId,bool admin,{required int? Function() authStatus})async{
    final denied=authStatus();if(denied!=null)return error(denied,denied==401?'unauthorized':'forbidden');
    final scope=_contract['context'] as Map;
    if(coreId!=scope['coreId']||homeId!=scope['homeId'])return error(404,'not_found');
    final path=request.uri.path,readBase='/api/v1/home-resources/$coreId/$homeId',
        aclBase='/api/v1/admin/home-resources/$coreId/$homeId/${target['ref']['id']}/grants';
    final isUsers=path=='/api/v1/admin/users',isAcl=path==aclBase||path.startsWith('$aclBase/'),
        isRecord=path==readBase||path=='$readBase/${target['ref']['id']}';
    if(!isUsers&&!isAcl&&!isRecord)return error(404,'not_found');
    if((isUsers||isAcl)&&!admin)return error(403,'forbidden');
    if((isUsers||isRecord)&&request.method!='GET'||isAcl&&!{'GET','PUT'}.contains(request.method))return error(403,'forbidden');
    if((isUsers||isAcl)&&request.uri.hasQuery)return error(400,'invalid_request');
    final bytes=<int>[];
    try{await for(final chunk in request.timeout(const Duration(seconds:2))){if(bytes.length+chunk.length>4096)return error(413,'invalid_request');bytes.addAll(chunk);}}
    on TimeoutException{return error(400,'invalid_request');}
    final afterBody=authStatus();if(afterBody!=null)return error(afterBody,afterBody==401?'unauthorized':'forbidden');
    if(request.method=='GET'){
      if(bytes.isNotEmpty)return error(400,'invalid_request');
      if(isUsers){usersReads++;return(200,{'users':users});}
      if(isRecord)return _readRecord(request,readBase,userId,admin);
      if(path!=aclBase)return error(404,'not_found');
      grantReads++;final ids=_grants.keys.toList()..sort();
      return(200,{'aclRevision':aclRevision,'grants':[for(final id in ids)_grant(id,_grants[id]!)]});
    }
    final id=path.startsWith('$aclBase/')?path.substring(aclBase.length+1):'';
    if(id.length!=32||!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)||!users.any((user)=>user['id']==id))return error(404,'not_found');
    Map<String,dynamic>? body;
    try{if(request.headers.contentType?.mimeType!='application/json')return error(400,'invalid_request');body=_body(utf8.decode(bytes));}
    on FormatException{return error(400,'invalid_request');}
    if(body==null||body.length!=2||!body.containsKey('expectedAclRevision')||!body.containsKey('permissions'))return error(400,'invalid_request');
    final revision=body['expectedAclRevision'],permissions=body['permissions'];
    if(revision is! int||revision<1||revision>9223372036854775807||permissions is! Map||permissions.length!=2||permissions['read'] is! bool||permissions['write'] is! bool||permissions['write']==true&&permissions['read']!=true)return error(400,'invalid_request');
    if(revision!=aclRevision)return error(409,'revision_conflict');
    final desired=Map<String,bool>.from(permissions),old=_grants[id]??{'read':false,'write':false};
    final changed=old['read']!=desired['read']||old['write']!=desired['write'];
    if(changed&&aclRevision==9223372036854775807)return error(409,'revision_conflict');
    putRequests++;
    if(changed){aclRevision++;if(desired['read']==true){_grants[id]=desired;}else{_grants.remove(id);}}
    mutations.add('PUT');
    final reply=(200,{'grant':_grant(id,desired)});
    final gate=replyGate;
    if(gate!=null){try{await gate.future.timeout(const Duration(seconds:3));}on TimeoutException{return error(503,'service_unavailable');}finally{if(identical(replyGate,gate))replyGate=null;}}
    final afterReply=authStatus();if(afterReply!=null)return error(afterReply,afterReply==401?'unauthorized':'forbidden');
    if(failNextPutReply){failNextPutReply=false;return error(503,'service_unavailable');}
    return reply;
  }
  Map<String,dynamic> _grant(String id,Map<String,bool> permissions)=>{'subjectId':id,'target':target['ref'],'aclRevision':aclRevision,'permissions':Map<String,bool>.from(permissions)};
  GrantsReply _readRecord(HttpRequest request,String base,String userId,bool admin){
    final permissions=admin?{'read':true,'write':true}:_grants[userId]??{'read':false,'write':false};
    final record={...target,'aclRevision':aclRevision,'permissions':permissions};
    final query=request.uri.queryParametersAll;
    if(query.values.any((v)=>v.length!=1))return error(400,'invalid_request');
    if(request.uri.path!=base){
      if(query.isNotEmpty)return error(400,'invalid_request');
      if(permissions['read']!=true)return error(404,'not_found');
      recordReads++;return(200,{'record':record});
    }
    if(query.keys.any((key)=>!{'limit','after','expectedSnapshot'}.contains(key)))return error(400,'invalid_request');
    final limit=query['limit']?.single??'25',after=query['after']?.single,expected=query['expectedSnapshot']?.single;
    if(!RegExp(r'^[1-9][0-9]{0,2}$').hasMatch(limit)||int.parse(limit)>100||after!=null&&(after.length!=32||!RegExp(r'^[0-9a-f]+$').hasMatch(after)||expected==null)||expected!=null&&(expected.length!=64||!RegExp(r'^[0-9a-f]+$').hasMatch(expected)))return error(400,'invalid_request');
    final entries=permissions['read']==true?[record]:<Map<String,dynamic>>[];
    final snapshot=sha256.convert(utf8.encode(jsonEncode(['grants-fixture-v1',userId,entries]))).toString();
    if(expected!=null&&expected!=snapshot)return error(409,'revision_conflict');
    if(after!=null&&(entries.isEmpty||after!=record['ref']['id']))return error(404,'not_found');
    recordReads++;return(200,{'scope':_contract['context'],'entries':after==null?entries:[],'snapshot':snapshot,'nextAfter':null});
  }
  // The four allowed keys are distinct across both nesting levels. Scan every
  // JSON key before decoding can discard duplicates (including escaped keys).
  static Map<String,dynamic>? _body(String text){
    final decoded=jsonDecode(text);if(decoded is! Map<String,dynamic>)return null;
    final keys=<String>{};var i=0;
    while(i<text.length){
      if(text.codeUnitAt(i)!=34){i++;continue;}
      final start=i++;
      while(i<text.length){final char=text.codeUnitAt(i++);if(char==92){i++;continue;}if(char==34)break;}
      final end=i;
      while(i<text.length&&const[9,10,13,32].contains(text.codeUnitAt(i))){i++;}
      if(i<text.length&&text[i]==':'){
        final key=jsonDecode(text.substring(start,end)) as String;
        if(!const{'expectedAclRevision','permissions','read','write'}.contains(key)||!keys.add(key))return null;
      }
    }
    return keys.length==4?decoded:null;
  }
}
