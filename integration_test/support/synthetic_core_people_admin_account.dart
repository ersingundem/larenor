import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:larenor/features/home_people/domain/home_person_models.dart';

import 'home_people_contract_fixture.dart';
import 'synthetic_core_account.dart';
import 'synthetic_core_resources.dart';

typedef _Reply = (int, Map<String, dynamic>?);

/// Explicit, disposable admin-person protocol; never production authorization,
/// SQLite, encryption or a grant to access the user's home. Effects are only
/// this fixture's bounded in-memory metadata. Dynamic snapshots are synthetic.
class SyntheticCorePeopleAdminAccount extends SyntheticCoreAccount {
  static final Map<String, dynamic> _contract =
      jsonDecode(homePeopleContractFixture) as Map<String, dynamic>;
  final _records = <Map<String, dynamic>>[];
  final _grants = <String, Map<String, bool>>{};
  final _mutations = <String>[];
  int peopleReads = 0, usersReads = 0, grantReads = 0;
  int _sequence = 0, _retiredLogin = 0;
  String role = 'admin';
  @override
  String get userId => 'f' * 32;
  @override
  String get currentAccessToken => 'synthetic-people-admin-session-$logins';
  @override
  Map<String, Object?> get user => {...super.user, 'role': role};
  List<Map<String, dynamic>> get records =>
      List.unmodifiable(_records.map(_clone));
  List<String> get mutations => List.unmodifiable(_mutations);
  String get subjectId => _contract['subjectId'] as String;
  String get firstId =>
      _contract['createPerson']['response']['person']['ref']['id'] as String;
  Completer<void>? bodyStarted, replyGate;
  void retireSession() => _retiredLogin = logins;
  static Map<String, dynamic> _clone(Map value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  static _Reply _error(int status, String code) => (
    status,
    {
      'error': {'code': code},
    },
  );
  static bool _matches(String pattern, String value) =>
      RegExp(pattern).firstMatch(value)?.end == value.length;
  static bool _id(String value) => _matches(r'^[0-9a-f]{32}$', value);
  static bool _revision(Object? value) =>
      value is int && value >= 1 && value <= 9223372036854775807;
  static bool _keys(Map value, Set<String> keys) =>
      value.length == keys.length && keys.every(value.containsKey);

  @override
  Future<void> handle(HttpRequest request) async {
    final path = request.uri.path;
    final personPath =
        path.startsWith('/api/v1/home-people') ||
        path.startsWith('/api/v1/admin/home-people');
    final resourcePath = path.startsWith('/api/v1/home-resources');
    final usersPath = path == '/api/v1/admin/users';
    if (!personPath && !resourcePath && !usersPath) {
      if (const {'/api/v1/auth/me', '/api/v1/context'}.contains(path) &&
          logins <= _retiredLogin) {
        await _respond(request, _error(401, 'unauthorized'));
      } else {
        await super.handle(request);
      }
      return;
    }
    final token = currentAccessToken,
        actor = userId,
        boundRole = role,
        core = coreId,
        home = homeId;
    _Reply? denied() {
      final headers = request.headers['authorization'];
      if (logins <= _retiredLogin ||
          headers == null ||
          headers.length != 1 ||
          headers.single != 'Bearer $currentAccessToken' ||
          token != currentAccessToken ||
          actor != userId)
        return _error(401, 'unauthorized');
      if (role != 'admin' ||
          role != boundRole ||
          user['mustChangePassword'] != false)
        return _error(403, 'forbidden');
      if (coreId != core ||
          homeId != home ||
          coreId != _contract['context']['coreId'] ||
          homeId != _contract['context']['homeId'])
        return _error(404, 'not_found');
      return null;
    }

    _Reply reply;
    try {
      final first = denied();
      if (first != null) {
        await _respond(request, first);
        return;
      }
      final readBase = '/api/v1/home-people/$core/$home',
          adminBase = '/api/v1/admin/home-people/$core/$home';
      final read = path == readBase || path.startsWith('$readBase/');
      final admin = path == adminBase || path.startsWith('$adminBase/');
      if (personPath && !read && !admin) {
        await _respond(request, _error(404, 'not_found'));
        return;
      }
      if ((read || usersPath || resourcePath) && request.method != 'GET') {
        await _respond(request, _error(403, 'forbidden'));
        return;
      }
      final query = request.uri.queryParametersAll;
      if (query.values.any((v) => v.length != 1)) {
        await _respond(request, _error(400, 'invalid_request'));
        return;
      }
      final started = bodyStarted;
      if (started != null && !started.isCompleted) started.complete();
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 2))) {
        if (bytes.length + chunk.length > 4096) {
          await _respond(request, _error(413, 'invalid_request'));
          return;
        }
        bytes.addAll(chunk);
      }
      final afterBody = denied();
      if (afterBody != null) {
        await _respond(request, afterBody);
        return;
      }
      if (request.method == 'GET' || request.method == 'DELETE') {
        if (bytes.isNotEmpty) {
          await _respond(request, _error(400, 'invalid_request'));
          return;
        }
      }
      if (usersPath) {
        if (query.isNotEmpty) {
          reply = _error(400, 'invalid_request');
        } else {
          usersReads++;
          reply = (
            200,
            {
              'users': [
                {
                  'id': subjectId,
                  'username': 'fixture-person-member',
                  'role': 'member',
                  'disabled': false,
                  'mustChangePassword': false,
                  'revision': 1,
                  'createdAt': '2026-09-06T00:00:00.000Z',
                },
              ],
            },
          );
        }
      } else if (resourcePath) {
        if (path != '/api/v1/home-resources/$core/$home') {
          reply = _error(404, 'not_found');
        } else {
          final response = SyntheticCoreResources.empty(userId: userId)
              .list(core, home, query);
          reply = (response.$1, _clone(response.$2 as Map));
        }
      } else if (read) {
        final id = path == readBase
            ? null
            : path.substring(readBase.length + 1);
        reply = _read(id, query);
      } else {
        final suffix = path == adminBase
            ? <String>[]
            : path.substring(adminBase.length + 1).split('/');
        Map<String, dynamic>? body;
        if (request.method != 'GET' && request.method != 'DELETE') {
          if (query.isNotEmpty ||
              request.headers.contentType?.mimeType != 'application/json') {
            await _respond(request, _error(400, 'invalid_request'));
            return;
          }
          body = _body(utf8.decode(bytes));
          if (body == null) {
            await _respond(request, _error(400, 'invalid_request'));
            return;
          }
        }
        final before = _mutations.length;
        reply = _admin(request.method, suffix, query, body);
        if (_mutations.length != before) {
          final gate = replyGate;
          replyGate = null;
          if (gate != null)
            await gate.future.timeout(const Duration(seconds: 2));
        }
      }
      // The response cannot carry old actor/scope authority after a delayed ACK.
      reply = denied() ?? reply;
    } on TimeoutException {
      reply = _error(503, 'service_unavailable');
    } on FormatException {
      reply = _error(400, 'invalid_request');
    }
    await _respond(request, reply);
  }

  Future<void> _respond(HttpRequest request, _Reply reply) async {
    if (reply.$1 >= 400) rejectedRequests++;
    final response = request.response;
    response.statusCode = reply.$1;
    response.headers.contentType = ContentType.json;
    if (reply.$2 != null) response.write(jsonEncode(reply.$2));
    await response.close();
  }

  _Reply _read(String? id, Map<String, List<String>> query) {
    if (id != null) {
      if (!_id(id)) return _error(404, 'not_found');
      if (query.isNotEmpty) return _error(400, 'invalid_request');
      final record = _records.where((v) => v['ref']['id'] == id).firstOrNull;
      if (record == null) return _error(404, 'not_found');
      peopleReads++;
      return (200, {'person': _clone(record)});
    }
    if (query.keys.any(
      (k) => !const {'limit', 'after', 'expectedSnapshot'}.contains(k),
    ))
      return _error(400, 'invalid_request');
    final rawLimit = query['limit']?.single ?? '25',
        limit = int.tryParse(rawLimit);
    final after = query['after']?.single,
        expected = query['expectedSnapshot']?.single;
    if (limit == null ||
        !_matches(r'^[1-9][0-9]{0,2}$', rawLimit) ||
        limit > 100 ||
        after != null && (!_id(after) || expected == null) ||
        expected != null && !_matches(r'^[0-9a-f]{64}$', expected))
      return _error(400, 'invalid_request');
    final all = records.toList()
      ..sort(
        (a, b) =>
            (a['ref']['id'] as String).compareTo(b['ref']['id'] as String),
      );
    final snapshot = _snapshot(all);
    if (expected != null && expected != snapshot)
      return _error(409, 'revision_conflict');
    if (after != null && !all.any((v) => v['ref']['id'] == after))
      return _error(404, 'not_found');
    final remaining = all
            .where(
              (v) =>
                  after == null ||
                  (v['ref']['id'] as String).compareTo(after) > 0,
            )
            .toList(),
        page = remaining.take(limit).toList();
    peopleReads++;
    return (
      200,
      {
        'scope': _clone(_contract['context'] as Map),
        'entries': page,
        'snapshot': snapshot,
        'nextAfter': remaining.length > limit ? page.last['ref']['id'] : null,
      },
    );
  }

  String _snapshot(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty)
      return _contract['emptyList']['response']['snapshot'] as String;
    if (_canonical(rows) ==
        _canonical(_contract['adminList']['response']['entries']))
      return _contract['adminList']['response']['snapshot'] as String;
    return sha256
        .convert(
          utf8.encode(
            'synthetic-people-admin-v1:$coreId:$homeId:$userId:${_canonical(rows)}',
          ),
        )
        .toString();
  }

  static String _canonical(Object? value) {
    Object? order(Object? v) => v is Map
        ? {
            for (final k in v.keys.cast<String>().toList()..sort())
              k: order(v[k]),
          }
        : v is List
        ? v.map(order).toList()
        : v;
    return jsonEncode(order(value));
  }

  _Reply _admin(
    String method,
    List<String> parts,
    Map<String, List<String>> query,
    Map<String, dynamic>? body,
  ) {
    if (parts.isEmpty && method == 'POST') {
      if (body == null || !_keys(body, {'label', 'order'}))
        return _error(400, 'invalid_request');
      final metadata = _metadata(body);
      if (metadata == null) return _error(400, 'invalid_request');
      if (_records.length >= 128 || _sequence >= 128)
        return _error(409, 'capacity_reached');
      final n = ++_sequence,
          id = n <= 2 ? '$n' * 32 : n.toRadixString(16).padLeft(32, '0');
      final record = <String, dynamic>{
        ...metadata.toJson(),
        'ref': {
          ..._clone(_contract['context'] as Map),
          'kind': 'person',
          'id': id,
        },
        'revision': 1,
        'aclRevision': 1,
        'permissions': {'read': true, 'write': true},
      };
      _records.add(record);
      _mutations.add(method);
      return (201, {'person': _clone(record)});
    }
    if (parts.isEmpty || !_id(parts.first)) return _error(404, 'not_found');
    final index = _records.indexWhere((r) => r['ref']['id'] == parts.first);
    if (index < 0) return _error(404, 'not_found');
    final record = _records[index];
    if (parts.length >= 2 && parts[1] == 'grants') {
      if (query.isNotEmpty) return _error(400, 'invalid_request');
      if (parts.length == 2 && method == 'GET') {
        grantReads++;
        final permission = _grants[parts.first];
        return (
          200,
          {
            'aclRevision': record['aclRevision'],
            'grants': [
              if (permission != null)
                {
                  'subjectId': subjectId,
                  'target': _clone(record['ref'] as Map),
                  'aclRevision': record['aclRevision'],
                  'permissions': {...permission},
                },
            ],
          },
        );
      }
      if (parts.length != 3 ||
          method != 'PUT' ||
          !_id(parts[2]) ||
          parts[2] != subjectId)
        return _error(404, 'not_found');
      if (body == null ||
          !_keys(body, {'expectedAclRevision', 'permissions'}) ||
          !_revision(body['expectedAclRevision']))
        return _error(400, 'invalid_request');
      final permission = body['permissions'];
      if (permission is! Map ||
          !_keys(permission, {'read', 'write'}) ||
          permission['read'] is! bool ||
          permission['write'] is! bool ||
          permission['write'] == true && permission['read'] != true)
        return _error(400, 'invalid_request');
      if (body['expectedAclRevision'] != record['aclRevision'])
        return _error(409, 'revision_conflict');
      final old = _grants[parts.first] ?? {'read': false, 'write': false};
      if (old['read'] != permission['read'] ||
          old['write'] != permission['write'])
        record['aclRevision'] = (record['aclRevision'] as int) + 1;
      if (permission['read'] == false) {
        _grants.remove(parts.first);
      } else {
        _grants[parts.first] = Map<String, bool>.from(permission);
      }
      _mutations.add(method);
      return (
        200,
        {
          'grant': {
            'subjectId': subjectId,
            'target': _clone(record['ref'] as Map),
            'aclRevision': record['aclRevision'],
            'permissions': Map<String, bool>.from(permission),
          },
        },
      );
    }
    if (parts.length != 1 || !const {'PATCH', 'DELETE'}.contains(method))
      return _error(404, 'not_found');
    Object? revision, aclRevision;
    HomePersonMetadata? metadata;
    if (method == 'PATCH') {
      if (body == null ||
          !_keys(body, {
            'label',
            'order',
            'expectedRevision',
            'expectedAclRevision',
          }))
        return _error(400, 'invalid_request');
      metadata = _metadata(body);
      revision = body['expectedRevision'];
      aclRevision = body['expectedAclRevision'];
      if (metadata == null) return _error(400, 'invalid_request');
    } else {
      if (!_keys(query, {'expectedRevision', 'expectedAclRevision'}))
        return _error(400, 'invalid_request');
      final r = query['expectedRevision']!.single,
          a = query['expectedAclRevision']!.single;
      if (!_matches(r'^[1-9][0-9]{0,18}$', r) ||
          !_matches(r'^[1-9][0-9]{0,18}$', a))
        return _error(400, 'invalid_request');
      revision = int.tryParse(r);
      aclRevision = int.tryParse(a);
    }
    if (!_revision(revision) || !_revision(aclRevision))
      return _error(400, 'invalid_request');
    if (revision != record['revision'] || aclRevision != record['aclRevision'])
      return _error(409, 'revision_conflict');
    _mutations.add(method);
    if (method == 'DELETE') {
      _records.removeAt(index);
      _grants.remove(parts.first);
      return (204, null);
    }
    if (record['label'] != metadata!.label || record['order'] != metadata.order)
      record['revision'] = (record['revision'] as int) + 1;
    record.addAll(metadata.toJson());
    return (200, {'person': _clone(record)});
  }

  static HomePersonMetadata? _metadata(Map body) {
    if (body['label'] is! String || body['order'] is! int) return null;
    try {
      return HomePersonMetadata(
        label: body['label'] as String,
        order: body['order'] as int,
      );
    } catch (_) {
      return null;
    }
  }

  // Closed bodies have unique names even across the one permitted nested map.
  static Map<String, dynamic>? _body(String text) {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) return null;
    final keys = <String>{};
    var i = 0;
    while (i < text.length) {
      if (text.codeUnitAt(i) != 34) {
        i++;
        continue;
      }
      final start = i++;
      while (i < text.length) {
        final c = text.codeUnitAt(i++);
        if (c == 92) {
          i++;
          continue;
        }
        if (c == 34) break;
      }
      final end = i;
      while (i < text.length &&
          const [9, 10, 13, 32].contains(text.codeUnitAt(i))) {
        i++;
      }
      if (i < text.length && text[i] == ':') {
        final k = jsonDecode(text.substring(start, end)) as String;
        if (!keys.add(k)) return null;
      }
    }
    return value;
  }
}
