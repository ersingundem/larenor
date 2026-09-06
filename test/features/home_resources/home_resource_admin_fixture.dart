import 'dart:async';
import 'dart:convert' show jsonDecode;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resources_fixture.dart';

class ResourceAdminHarness extends ResourceHarness {
  ResourceAdminHarness({super.pinStore}) {
    records.addAll(
      (fixture['adminList']['entries'] as List)
          .take(2)
          .map((raw) => Map<String, dynamic>.from(raw as Map)),
    );
  }
  String role = 'admin';
  final records = <Map<String, dynamic>>[];
  final mutations = <http.Request>[];
  Completer<http.Response>? pendingMutation;
  int mutationStatus = 200;
  bool passwordRequired = false;
  bool failList = false;
  bool corruptMutation = false;
  @override
  Map<String, Object?> get user => {
    ...super.user,
    'role': role,
    'mustChangePassword': passwordRequired,
  };
  @override
  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.contains('/admin/home-resources/')) {
      mutations.add(request);
      expectSync(request.method, isIn(['POST', 'PATCH', 'DELETE']));
      final body = request.body.isEmpty
          ? null
          : jsonDecode(request.body) as Map;
      if (mutationStatus != 200) {
        return pendingMutation?.future ??
            json({
              'error': {
                'code': mutationStatus == 409
                    ? 'revision_conflict'
                    : 'unauthorized',
                'message': 'private-upstream',
              },
            }, mutationStatus);
      }
      Map<String, dynamic>? result;
      if (request.method == 'POST') {
        expectSync(body!.keys.toSet(), {'kind', 'label', 'order'});
        result = {
          'ref': {
            ...fixture['context'] as Map,
            'id': (records.length + 3).toRadixString(16).padLeft(32, '0'),
            'kind': body['kind'],
          },
          'label': body['label'],
          'order': body['order'],
          'revision': 1,
          'aclRevision': 1,
          'permissions': {'read': true, 'write': true},
        };
        records.add(result);
      } else {
        final id = request.url.pathSegments.last;
        final index = records.indexWhere((record) => record['ref']['id'] == id);
        expectSync(index, greaterThanOrEqualTo(0));
        final previous = records[index];
        if (request.method == 'PATCH') {
          expectSync(body!.keys.toSet(), {
            'label',
            'order',
            'expectedRevision',
            'expectedAclRevision',
          });
          expectSync(body['expectedRevision'], previous['revision']);
          expectSync(body['expectedAclRevision'], previous['aclRevision']);
          final changed =
              body['label'] != previous['label'] ||
              body['order'] != previous['order'];
          result = {
            ...previous,
            'label': body['label'],
            'order': body['order'],
            'revision': (previous['revision'] as int) + (changed ? 1 : 0),
          };
          records[index] = result;
        } else {
          expectSync(request.url.queryParameters, {
            'expectedRevision': '${previous['revision']}',
            'expectedAclRevision': '${previous['aclRevision']}',
          });
          records.removeAt(index);
        }
      }
      final reply = request.method == 'DELETE'
          ? http.Response('', 204)
          : json({
              'record': corruptMutation
                  ? {...result!, 'revision': 999}
                  : result,
            }, request.method == 'POST' ? 201 : 200);
      return pendingMutation?.future ?? reply;
    }
    if (request.url.path.contains('/home-resources/') &&
        request.method == 'GET') {
      resourceReads++;
      if (failList) {
        return json({
          'error': {'code': 'service_unavailable'},
        }, 503);
      }
      final sorted = records.toList()
        ..sort(
          (a, b) =>
              (a['ref']['id'] as String).compareTo(b['ref']['id'] as String),
        );
      final cursor = request.url.queryParameters['after'];
      final rest = sorted
          .where(
            (record) =>
                cursor == null ||
                (record['ref']['id'] as String).compareTo(cursor) > 0,
          )
          .toList();
      final page = rest.take(25).toList();
      return json({
        'scope': fixture['context'],
        'entries': page,
        'snapshot': 'a' * 64,
        'nextAfter': rest.length > page.length ? page.last['ref']['id'] : null,
      });
    }
    return super.handle(request);
  }
}

Finder adminKey(String key) => find.byKey(ValueKey(key));
Future<void> adminPress(WidgetTester tester, String key) async {
  final target = adminKey(key);
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await flush(tester);
  await tester.tap(target);
  await flush(tester);
}

Future<void> openAdmin(
  WidgetTester tester,
  ResourceAdminHarness harness, {
  String? pin,
}) async {
  await harness.mount(tester, pin: pin);
  await harness.signIn();
  await flush(tester);
  await adminPress(tester, 'home-resources-manage');
  if (pin != null) {
    expect(adminKey('home-resource-admin'), findsNothing);
    expect(harness.mutations, isEmpty);
    await tester.enterText(find.byType(CupertinoTextField), pin);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await flush(tester);
  }
  expect(adminKey('home-resource-admin'), findsOneWidget);
}
