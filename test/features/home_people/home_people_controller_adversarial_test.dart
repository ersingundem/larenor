import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/home_people/data/home_people_controller.dart';
import 'package:larenor/features/home_people/data/home_people_providers.dart';
import 'package:larenor/features/home_people/data/home_person_grants_controller.dart';
import 'package:larenor/features/home_people/domain/home_person_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'home_people_controller_fixture.dart';
import 'home_person_models_test.dart' show copy;

Map<String, dynamic> page(
  PeopleHarness h,
  int start,
  int count, {
  bool more = false,
}) {
  final value = copy(h.f['adminList']['response']);
  value['entries'] = List.generate(count, (i) {
    final record = copy(h.f['adminList']['response']['entries'][0]);
    record['ref']['id'] = (start + i).toRadixString(16).padLeft(32, '0');
    return record;
  });
  value['nextAfter'] = more
      ? (value['entries'] as List).last['ref']['id']
      : null;
  return value;
}

void main() {
  for (final extra in [false, true]) {
    testWidgets(
      '128 person total ${extra ? 'rejects continuation' : 'remains reachable'}',
      (tester) async {
        final h = PeopleHarness();
        h.reply = (r) async => jsonResponse(
          r.url.queryParameters.containsKey('after')
              ? page(h, 101, 28, more: extra)
              : page(h, 1, 100, more: true),
        );
        await h.mount(tester, pageSize: 100);
        expect(h.list!.entries.length, 100);
        await h.list!.loadMore();
        expect(h.list!.entries.length, extra ? 0 : 128);
        expect(h.list!.failure, extra ? 'invalid_response' : null);
        expect(h.list!.canLoadMore, isFalse);
      },
    );
  }
  for (final corruption in ['foreign', 'duplicate', 'snapshot', 'oversize']) {
    testWidgets(
      'second page $corruption clears the snapshot without partial publication',
      (tester) async {
        final h = PeopleHarness()..listStep = 'firstPage';
        await h.mount(tester, pageSize: 1);
        final invalid = copy(h.f['secondPage']['response']) as Map;
        if (corruption == 'foreign') {
          invalid['scope'] = h.f['otherContextList']['response']['scope'];
        }
        if (corruption == 'duplicate') {
          invalid['entries'] = h.f['firstPage']['response']['entries'];
        }
        if (corruption == 'snapshot') invalid['snapshot'] = '0' * 64;
        if (corruption == 'oversize') {
          invalid['entries'] = h.f['memberList']['response']['entries'];
        }
        h.reply = (_) async => jsonResponse(invalid);
        await h.list!.loadMore();
        expect(h.list!.entries, isEmpty);
        expect(h.list!.failure, 'invalid_response');
        expect(h.requests.length, 2);
      },
    );
  }
  testWidgets(
    'single-flight blocks read/write overlap and stale selected record',
    (tester) async {
      final h = PeopleHarness();
      await h.mount(tester);
      final c = h.list!,
          old = c.entries.first,
          pending = Completer<http.Response>();
      h.reply = (_) => pending.future;
      final refresh = c.refresh();
      await settle(tester);
      await c.refresh();
      await c.loadMore();
      await c.create(label: 'Blocked', order: 0, isCurrent: () => true);
      expect(h.requests.length, 2);
      pending.complete(jsonResponse(h.f['adminList']['response']));
      await refresh;
      h.reply = null;
      await c.update(old, label: 'Stale', order: 0, isCurrent: () => true);
      await c.delete(old, isCurrent: () => true);
      await c.create(
        label: 'Denied',
        order: 0,
        isCurrent: () => throw StateError('private'),
      );
      expect(h.requests.length, 2);
    },
  );
  testWidgets(
    'successful create is one POST and explicit refresh restores paging',
    (tester) async {
      final h = PeopleHarness()
        ..listStep = 'emptyList'
        ..writeStep = 'createPerson';
      await h.mount(tester);
      final c = h.list!;
      await c.create(label: 'Deniz Öztürk', order: 7, isCurrent: () => true);
      expect(c.entries.single.id, '1' * 32);
      expect(c.mutationOutcome, HomePersonMutationOutcome.saved);
      expect(h.requests.length, 2);
      expect(c.snapshot, isNull);
      h.listStep = 'adminList';
      await c.refresh();
      expect(c.entries.length, 2);
      expect(c.snapshot, isNotNull);
      expect(h.requests.where((r) => r.method == 'POST').length, 1);
    },
  );
  for (final code in ['revision_conflict', 'forbidden', 'invalid_request']) {
    testWidgets(
      'metadata $code is visible and requires GET before another write',
      (tester) async {
        final h = PeopleHarness();
        await h.mount(tester);
        final c = h.list!;
        h.reply = (_) async => jsonResponse(
          {
            'error': {'code': code},
          },
          code == 'revision_conflict'
              ? 409
              : code == 'forbidden'
              ? 403
              : 400,
        );
        await c.delete(c.entries.first, isCurrent: () => true);
        expect(c.failure, code);
        expect(
          c.mutationOutcome,
          code == 'revision_conflict'
              ? HomePersonMutationOutcome.conflict
              : HomePersonMutationOutcome.failed,
        );
        expect(c.entries, isEmpty);
        expect(c.canMutate, isFalse);
      },
    );
  }
  testWidgets(
    'freshness timer clears before access expiry without automatic auth POST',
    (tester) async {
      final h = PeopleHarness();
      await h.mount(tester);
      h.now = h.now.add(const Duration(minutes: 59, seconds: 30));
      await tester.pump(const Duration(minutes: 59, seconds: 30));
      expect(h.list!.entries, isEmpty);
      expect(h.list!.fresh, isFalse);
      expect(h.auth.refreshes, 0);
      expect(h.requests.length, 1);
    },
  );
  testWidgets(
    'external token rotation rejects old401 while retaining new verified pair',
    (tester) async {
      final h = PeopleHarness(), late = Completer<http.Response>();
      h.reply = (r) async => h.requests.length == 1
          ? late.future
          : jsonResponse(h.f['adminList']['response']);
      await h.mount(tester);
      h.now = h.now.add(const Duration(minutes: 59, seconds: 40));
      await h.account.ensureSession();
      late.complete(
        jsonResponse({
          'error': {'code': 'unauthorized'},
        }, 401),
      );
      await settle(tester);
      expect(h.account.session!.accessToken, 'access-1');
      expect(h.store.value!.accessToken, 'access-1');
      expect(h.account.failure, isNull);
      expect(h.list!.entries.length, 2);
    },
  );
  testWidgets('missing home provider remains unavailable with zero transport', (
    tester,
  ) async {
    final h = PeopleHarness(),
        container = ProviderContainer(
          overrides: [
            homePeopleApiFactoryProvider.overrideWithValue(
              (_) => throw StateError('must not construct'),
            ),
          ],
        );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(home: PeopleProbe(h: h)),
      ),
    );
    await settle(tester);
    expect(h.list!.entries, isEmpty);
    expect(h.list!.fresh, isFalse);
    await h.list!.refresh();
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    h.owner.dispose();
    h.interaction.dispose();
  });
  testWidgets(
    'provider invalidation retires old read while original widget stays mounted',
    (tester) async {
      final h = PeopleHarness();
      await h.mount(tester);
      final c = h.list!;
      h.container.invalidate(
        homePeopleControllerProvider((
          owner: h.owner,
          adminManagement: true,
          pageSize: 25,
        )),
      );
      await settle(tester);
      await c.refresh();
      await h.list!.refresh();
      expect(h.owner.isCurrent, isFalse);
      expect(h.requests.length, 1);
      expect(h.list!.entries, isEmpty);
    },
  );
  for (final status in [200, 401]) {
    testWidgets(
      'late admin users $status under lost PIN never starts person ACL GET',
      (tester) async {
        final h = PeopleHarness(), late = Completer<http.Response>();
        h.reply = (_) => late.future;
        await h.mount(tester, acl: true);
        expect(h.requests.length, 1);
        h.pin = false;
        late.complete(
          jsonResponse(
            status == 200
                ? {
                    'users': [h.user()],
                  }
                : {
                    'error': {'code': 'unauthorized'},
                  },
            status,
          ),
        );
        await settle(tester);
        expect(h.account.session, isNotNull);
        expect(h.grants!.snapshot, isNull);
        expect(h.grants!.users, isEmpty);
        expect(h.requests.length, 1);
      },
    );
  }
  for (final invalid in ['malformed', 'duplicate', 'overLimit']) {
    testWidgets(
      'invalid account catalog $invalid cannot name a grant subject',
      (tester) async {
        final h = PeopleHarness();
        final users = [h.user()];
        if (invalid == 'malformed') users[0]['id'] = 'x';
        if (invalid == 'duplicate') users.add(h.user());
        if (invalid == 'overLimit') {
          users.addAll(List.generate(256, (_) => h.user()));
        }
        h.reply = (_) async => jsonResponse({'users': users});
        await h.mount(tester, acl: true);
        expect(h.grants!.failure, 'invalid_response');
        expect(h.grants!.users, isEmpty);
        expect(h.requests.length, 1);
      },
    );
  }
  for (final denied in ['member', 'foreign']) {
    testWidgets('ACL $denied is not an admin person target', (tester) async {
      final h = PeopleHarness();
      final context = h.context;
      if (denied == 'member') h.role = ServerRole.member;
      if (denied == 'foreign') {
        final _ = h.target;
        h.context = ServerContext.fromJson(
          h.f['otherContextList']['response']['scope'],
        );
        expect(h.target.context, context);
      }
      await h.mount(tester, acl: true);
      await h.grants!.refresh();
      expect(h.transports, 0);
      expect(h.grants!.users, isEmpty);
    });
  }
  testWidgets(
    'ACL minimum survives a failed GET; previous snapshot cannot roll back',
    (tester) async {
      final h = PeopleHarness();
      await h.mount(tester, acl: true);
      final c = h.grants!;
      h.writeStep = 'grantWrite';
      await c.setPermission(
        c.users.single,
        HomePersonPermission.readWrite,
        isCurrent: () => true,
      );
      expect(c.snapshot!.aclRevision, 3);
      h.reply = (_) async => jsonResponse(null, 503);
      await c.refresh();
      expect(c.snapshot, isNull);
      h.reply = null;
      await c.refresh();
      expect(c.failure, 'invalid_response');
      expect(c.snapshot, isNull);
      h.grantStep = 'afterRevoke';
      await c.refresh();
      expect(c.snapshot!.aclRevision, 4);
    },
  );
  for (final status in [200, 401, 409]) {
    testWidgets(
      'late ACL PUT $status never overwrites a retired confirmation',
      (tester) async {
        final h = PeopleHarness();
        await h.mount(tester, acl: true);
        final c = h.grants!, late = Completer<http.Response>();
        h.reply = (_) => late.future;
        bool active = true;
        final change = c.setPermission(
          c.users.single,
          HomePersonPermission.readWrite,
          isCurrent: () => active,
        );
        await settle(tester);
        active = false;
        late.complete(
          jsonResponse(
            status == 200
                ? h.f['grantWrite']['response']
                : {
                    'error': {
                      'code': status == 401
                          ? 'unauthorized'
                          : 'revision_conflict',
                    },
                  },
            status,
          ),
        );
        await change;
        expect(c.snapshot, isNull);
        expect(c.outcome, isNull);
        expect(h.account.session, isNotNull);
        expect(h.requests.where((r) => r.method == 'PUT').length, 1);
      },
    );
  }
  testWidgets(
    'active ACL401 rejects account, ordinary conflict keeps account',
    (tester) async {
      final h = PeopleHarness();
      await h.mount(tester, acl: true);
      final c = h.grants!;
      h.reply = (_) async => jsonResponse({
        'error': {'code': 'revision_conflict'},
      }, 409);
      await c.setPermission(
        c.users.single,
        HomePersonPermission.readWrite,
        isCurrent: () => true,
      );
      expect(c.outcome, HomePersonGrantOutcome.conflict);
      expect(h.account.session, isNotNull);
      h.reply = (_) async => jsonResponse({
        'error': {'code': 'unauthorized'},
      }, 401);
      await c.refresh();
      expect(h.account.session, isNull);
      expect(h.store.value, isNull);
    },
  );
}
