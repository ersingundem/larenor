import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/admin/data/server_admin_controller.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'server_admin_test_support.dart';

void main() {
  late AdminFixture fixture;
  late ServerAdminController admin;
  bool current() => true;
  setUp(() async {
    fixture = AdminFixture();
    await fixture.account.initialize();
    admin = ServerAdminController(fixture.account);
  });
  tearDown(() {
    admin.dispose();
    fixture.account.dispose();
  });

  test(
    'create, edit and other-user reset use authenticated revision contracts',
    () async {
      await admin.load(AdminTab.users, current: current);
      expect(admin.users.length, 2);
      await admin.create(
        username: 'New.Member',
        role: ServerRole.member,
        password: adminPassword,
        current: current,
      );
      expect(admin.users.last.username, 'new.member');
      expect(admin.users.last.mustChangePassword, isTrue);
      final member = admin.users.firstWhere((user) => user.id == memberId);
      await admin.update(
        member,
        role: ServerRole.admin,
        disabled: false,
        current: current,
      );
      final changed = admin.users.firstWhere((user) => user.id == memberId);
      expect(changed.revision, 2);
      await admin.resetPassword(changed, adminPassword, current: current);
      await admin.resetPassword(
        admin.users.firstWhere((user) => user.id == adminId),
        adminPassword,
        current: current,
      );
      expect(fixture.mutations.length, 3);
      final requests = fixture.mutations.toList();
      expect(requests.map((request) => request.method), [
        'POST',
        'PATCH',
        'POST',
      ]);
      expect(jsonDecode(requests[0].body), {
        'username': 'New.Member',
        'role': 'member',
        'initialPassword': adminPassword,
      });
      expect(jsonDecode(requests[1].body), {
        'expectedRevision': 1,
        'role': 'admin',
        'disabled': false,
      });
      expect(jsonDecode(requests[2].body), {
        'expectedRevision': 2,
        'temporaryPassword': adminPassword,
      });
      expect(
        fixture.adminCalls.every(
          (request) =>
              request.url.path.startsWith('/prefix/api/v1/admin/') &&
              request.headers['authorization'] ==
                  'Bearer synthetic_admin_access_12345',
        ),
        isTrue,
      );
      expect(admin.changed, isTrue);
      expect(admin.failure, isNull);
    },
  );

  for (final code in [
    'last_active_admin',
    'revision_conflict',
    'server_unavailable',
  ]) {
    test(
      '$code requires explicit read before another mutation and never retries',
      () async {
        await admin.load(AdminTab.users, current: current);
        final user = admin.users.first;
        fixture.respond = (_) async => fixture.json({
          'error': {'code': code},
        }, code == 'server_unavailable' ? 503 : 409);
        await admin.update(
          user,
          role: ServerRole.member,
          disabled: true,
          current: current,
        );
        expect(admin.changed, isFalse);
        expect(admin.needsRefresh, isTrue);
        expect(fixture.mutations.length, 1);
        await admin.update(
          user,
          role: ServerRole.member,
          disabled: true,
          current: current,
        );
        expect(fixture.mutations.length, 1);
        fixture.respond = null;
        await admin.load(AdminTab.users, current: current);
        expect(admin.needsRefresh, isFalse);
        expect(admin.failure, isNull);
        await admin.update(
          admin.users.first,
          role: ServerRole.admin,
          disabled: false,
          current: current,
        );
        expect(fixture.mutations.length, 2);
      },
    );
  }

  test(
    'pending write is single flight and account loss discards its response',
    () async {
      final pending = Completer<http.Response>();
      fixture.respond = (_) => pending.future;
      final operation = admin.create(
        username: 'member2',
        role: ServerRole.member,
        password: adminPassword,
        current: current,
      );
      await Future<void>.delayed(Duration.zero);
      await admin.create(
        username: 'member3',
        role: ServerRole.member,
        password: adminPassword,
        current: current,
      );
      expect(fixture.mutations.length, 1);
      await fixture.account.signOut();
      pending.complete(fixture.json({'user': adminUserJson()}));
      await operation;
      expect(admin.users, isEmpty);
      expect(admin.changed, isFalse);
      expect(admin.busy, isFalse);
    },
  );

  test('accepted self-demotion immediately clears cached administrator credentials', () async {
    await admin.load(AdminTab.users, current: current);
    await admin.update(
      admin.users.first,
      role: ServerRole.member,
      disabled: false,
      current: current,
    );
    expect(fixture.mutations.length, 1);
    expect(fixture.account.session, isNull);
    expect(fixture.store.value, isNull);
    expect(admin.users, isEmpty);
    expect(
      fixture.calls.where(
        (request) => request.url.path.endsWith('/auth/logout'),
      ),
      isEmpty,
    );
    await admin.create(
      username: 'member2',
      role: ServerRole.member,
      password: adminPassword,
      current: current,
    );
    expect(fixture.mutations.length, 1);
  });

  test(
    'visibility lost during refresh prevents sending the pending mutation',
    () async {
      fixture.now = fixture.now.add(const Duration(hours: 2));
      fixture.refresh = Completer();
      var visible = true;
      final operation = admin.create(
        username: 'member2',
        role: ServerRole.member,
        password: adminPassword,
        current: () => visible,
      );
      await Future<void>.delayed(Duration.zero);
      visible = false;
      admin.invalidate();
      fixture.refresh!.complete(fixture.pair());
      await operation;
      expect(fixture.mutations, isEmpty);
      expect(admin.users, isEmpty);
    },
  );

  test(
    'refreshed member role cancels operation and future administrator calls',
    () async {
      fixture.now = fixture.now.add(const Duration(hours: 2));
      fixture.refresh = Completer();
      final operation = admin.load(AdminTab.users, current: current);
      await Future<void>.delayed(Duration.zero);
      fixture.user = ServerUser(
        id: adminId,
        username: 'admin',
        role: ServerRole.member,
        mustChangePassword: false,
      );
      fixture.refresh!.complete(fixture.pair());
      await operation;
      await admin.create(
        username: 'member2',
        role: ServerRole.member,
        password: adminPassword,
        current: current,
      );
      await admin.load(AdminTab.users, current: current);
      expect(fixture.account.session!.user.role, ServerRole.member);
      expect(fixture.adminCalls, isEmpty);
    },
  );

  test(
    'read results arriving after invalidation cannot repopulate a hidden list',
    () async {
      final pending = Completer<http.Response>();
      fixture.respond = (_) => pending.future;
      final operation = admin.load(AdminTab.users, current: current);
      await Future<void>.delayed(Duration.zero);
      admin.invalidate();
      pending.complete(fixture.json({'users': fixture.users}));
      await operation;
      expect(admin.users, isEmpty);
      expect(admin.failure, isNull);
    },
  );

  test(
    'audit pages use descending opaque IDs and reject a repeated cursor',
    () async {
      fixture.respond = (request) async {
        final cursor = request.url.queryParameters['cursor'];
        expect(request.url.queryParameters['limit'], '50');
        return fixture.json(
          cursor == null
              ? {
                  'events': [adminEventJson('3'), adminEventJson('2')],
                  'nextCursor': '2',
                }
              : {
                  'events': [adminEventJson('1')],
                  'nextCursor': null,
                },
        );
      };
      await admin.load(AdminTab.audit, current: current);
      await admin.load(AdminTab.audit, more: true, current: current);
      expect(admin.audit.map((event) => event.id), ['3', '2', '1']);
      expect(fixture.adminCalls.last.url.queryParameters['cursor'], '2');
      expect(admin.auditCursor, isNull);
      final before = fixture.adminCalls.length;
      await admin.load(AdminTab.audit, more: true, current: current);
      expect(fixture.adminCalls.length, before);
      fixture.respond = (_) async => fixture.json({
        'events': [adminEventJson('4'), adminEventJson('4')],
        'nextCursor': '4',
      });
      await admin.load(AdminTab.audit, current: current);
      expect(admin.failure, 'invalid_response');
      expect(admin.audit.map((event) => event.id), ['3', '2', '1']);
    },
  );

  test(
    'revoke performs one DELETE and one explicit fresh session read',
    () async {
      await admin.load(AdminTab.sessions, current: current);
      await admin.revoke(admin.sessions.single, current: current);
      expect(fixture.mutations.single.method, 'DELETE');
      expect(
        fixture.mutations.single.url.path,
        '/prefix/api/v1/admin/sessions/$deviceId',
      );
      expect(admin.sessions.single.revokedAt, isNotNull);
      expect(fixture.adminCalls.length, 3);
      expect(admin.changed, isTrue);
    },
  );
}
