import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/home_people/data/home_people_controller.dart';
import 'package:larenor/features/home_people/data/home_person_grants_controller.dart';
import 'package:larenor/features/home_people/domain/home_person_models.dart';
import 'package:larenor/features/server/admin/domain/server_admin_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_people_controller_fixture.dart';
import 'home_person_models_test.dart' show copy;

void main() {
  testWidgets(
    'mounted provider reads exact current Core and explicit refresh only',
    (tester) async {
      final h = PeopleHarness();
      await h.mount(tester);
      expect(h.list!.entries.length, 2);
      expect(h.list!.snapshot, h.f['adminList']['response']['snapshot']);
      expect(h.list!.canMutate, isTrue);
      expect(h.transports, 1);
      expect(h.closes, 1);
      expect(() => h.list!.entries.clear(), throwsUnsupportedError);
      await h.list!.refresh();
      expect(h.requests.length, 2);
    },
  );
  testWidgets(
    'actual snapshot pages append and stale snapshot clears without retry',
    (tester) async {
      final h = PeopleHarness()..listStep = 'firstPage';
      await h.mount(tester, pageSize: 1);
      expect(h.list!.entries.length, 1);
      expect(h.list!.canLoadMore, isTrue);
      h.listStep = 'secondPage';
      await h.list!.loadMore();
      expect(h.list!.entries.length, 2);
      expect(h.list!.canLoadMore, isFalse);
      expect(h.requests.last.url.queryParameters['after'], '1' * 32);
      expect(
        h.requests.last.url.queryParameters['expectedSnapshot'],
        h.f['firstPage']['response']['snapshot'],
      );
      h.listStep = 'firstPage';
      await h.list!.refresh();
      h.listStep = 'stalePage';
      await h.list!.loadMore();
      expect(h.list!.entries, isEmpty);
      expect(h.list!.failure, 'revision_conflict');
      expect(h.requests.length, 4);
    },
  );
  testWidgets('metadata update and delete use frozen known revisions', (
    tester,
  ) async {
    final h = PeopleHarness();
    await h.mount(tester);
    final c = h.list!;
    await c.update(
      c.entries.first,
      label: 'Ece Öztürk',
      order: 0,
      isCurrent: () => true,
    );
    expect(c.mutationOutcome, HomePersonMutationOutcome.saved);
    expect(c.entries.firstWhere((e) => e.id == '1' * 32).revision, 2);
    expect(c.snapshot, isNull);
    expect(c.nextAfter, isNull);
    h.writeStep = 'deletePerson';
    await c.delete(
      c.entries.firstWhere((e) => e.id == '1' * 32),
      isCurrent: () => true,
    );
    expect(c.mutationOutcome, HomePersonMutationOutcome.deleted);
    expect(c.entries.length, 1);
  });
  testWidgets(
    'uncertain create blocks mutation until explicit GET without replay',
    (tester) async {
      final h = PeopleHarness();
      await h.mount(tester);
      final c = h.list!;
      h.reply = (_) async => jsonResponse(null, 503);
      await c.create(label: 'New', order: 0, isCurrent: () => true);
      expect(c.mutationOutcome, HomePersonMutationOutcome.uncertain);
      expect(c.canMutate, isFalse);
      expect(c.entries, isEmpty);
      await c.create(label: 'New', order: 0, isCurrent: () => true);
      expect(h.requests.length, 2);
      h.reply = null;
      await c.refresh();
      expect(c.canMutate, isTrue);
      expect(h.requests.where((r) => r.method == 'POST').length, 1);
    },
  );
  testWidgets('member readWrite is not admin metadata or ACL authority', (
    tester,
  ) async {
    final h = PeopleHarness()..role = ServerRole.member;
    final body = copy(h.f['memberList']['response']) as Map;
    for (final record in body['entries'] as List) {
      record['permissions']['write'] = true;
    }
    h.reply = (_) async => jsonResponse(body);
    await h.mount(tester, admin: false);
    expect(h.list!.entries.length, 2);
    expect(h.list!.entries.first.canWrite, isTrue);
    expect(h.list!.canManage, isFalse);
    await h.list!.create(label: 'Denied', order: 0, isCurrent: () => true);
    expect(h.requests.length, 1);
  });
  for (final denied in ['direct', 'memberAdmin', 'password']) {
    testWidgets('$denied no feature transport', (tester) async {
      final h = PeopleHarness();
      if (denied == 'direct') h.source.value = HomeSource.directLocal;
      if (denied == 'memberAdmin') h.role = ServerRole.member;
      if (denied == 'password') h.mustChangePassword = true;
      await h.mount(tester);
      await h.list!.refresh();
      expect(h.requests, isEmpty);
      expect(h.transports, 0);
      expect(h.list!.entries, isEmpty);
    });
  }
  for (final status in [200, 401]) {
    for (final boundary in ['PIN', 'route', 'window', 'source', 'logout']) {
      testWidgets(
        'late $status after $boundary retires metadata without stale auth rejection',
        (tester) async {
          final h = PeopleHarness(), pending = Completer<http.Response>();
          h.reply = (_) => pending.future;
          await h.mount(tester);
          expect(h.requests.length, 1);
          if (boundary == 'PIN') h.pin = false;
          if (boundary == 'route') h.route = false;
          if (boundary == 'window') h.interaction.setActive(false);
          if (boundary == 'source') await h.home.choose(HomeSource.directLocal);
          if (boundary == 'logout') await h.account.signOut();
          h.owner.synchronize();
          pending.complete(
            jsonResponse(
              status == 200
                  ? h.f['adminList']['response']
                  : {
                      'error': {'code': 'unauthorized'},
                    },
              status,
            ),
          );
          await settle(tester);
          expect(h.list!.entries, isEmpty);
          expect(h.store.value == null, boundary == 'logout');
          expect(h.account.session == null, boundary == 'logout');
        },
      );
    }
  }
  testWidgets('active current 401 rejects account and durable session', (
    tester,
  ) async {
    final h = PeopleHarness()
      ..reply = (_) async => jsonResponse({
        'error': {'code': 'unauthorized'},
      }, 401);
    await h.mount(tester);
    expect(h.account.session, isNull);
    expect(h.store.value, isNull);
    expect(h.list!.entries, isEmpty);
  });
  testWidgets(
    'ACL selected actual user read write revoke and monotonic GET recovery',
    (tester) async {
      final h = PeopleHarness();
      await h.mount(tester, acl: true);
      final c = h.grants!;
      expect(c.snapshot!.aclRevision, 2);
      expect(c.users.length, 1);
      h.writeStep = 'grantWrite';
      await c.setPermission(
        c.users.single,
        HomePersonPermission.readWrite,
        isCurrent: () => true,
      );
      expect(c.snapshot!.aclRevision, 3);
      h.writeStep = 'revoke';
      await c.setPermission(
        c.users.single,
        HomePersonPermission.none,
        isCurrent: () => true,
      );
      expect(c.outcome, HomePersonGrantOutcome.revoked);
      expect(c.snapshot!.aclRevision, 4);
      await c.refresh();
      expect(c.snapshot, isNull);
      expect(c.failure, 'invalid_response');
      h.grantStep = 'afterRevoke';
      await c.refresh();
      expect(c.snapshot!.aclRevision, 4);
    },
  );
  testWidgets('ACL invented user and retired owner cannot dispatch PUT', (
    tester,
  ) async {
    final h = PeopleHarness();
    await h.mount(tester, acl: true);
    final c = h.grants!;
    expect(c.users, isNotEmpty);
    await c.setPermission(
      AdminUser.fromJson(h.user()),
      HomePersonPermission.readWrite,
      isCurrent: () => true,
    );
    await c.setPermission(
      c.users.single,
      HomePersonPermission.readWrite,
      isCurrent: () => false,
    );
    expect(h.requests.where((r) => r.method == 'PUT'), isEmpty);
  });
  testWidgets('ACL uncertain PUT requires explicit users plus grants GET', (
    tester,
  ) async {
    final h = PeopleHarness();
    await h.mount(tester, acl: true);
    final c = h.grants!;
    h.reply = (_) async => jsonResponse(null, 503);
    await c.setPermission(
      c.users.single,
      HomePersonPermission.readWrite,
      isCurrent: () => true,
    );
    expect(c.outcome, HomePersonGrantOutcome.uncertain);
    expect(c.snapshot, isNull);
    expect(c.users, isEmpty);
    h.reply = null;
    await c.refresh();
    expect(c.canChange, isTrue);
    expect(h.requests.where((r) => r.method == 'PUT').length, 1);
  });
}
