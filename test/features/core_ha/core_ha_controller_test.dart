import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

import 'core_ha_controller_fixture.dart';

void main() {
  testWidgets(
    'mounted provider selected resource GET then switch GET, no command',
    (tester) async {
      final h = HaHarness();
      await h.mount(tester, admin: false);
      expect(h.list!.snapshot?.projection.state.name, 'off');
      expect(h.list!.snapshot!.projection.commandAvailable, isFalse);
      expect(h.requests.map((r) => r.method), ['GET', 'GET']);
      expect(h.list!.record!.id, h.target.id);
      expect(h.closes, 1);
    },
  );
  testWidgets(
    'TTL subtracts network duration and stale clears projection without GET',
    (tester) async {
      final h = HaHarness();
      h.reply = (r) async {
        if (r.url.path.contains('/home-resources/')) {
          return jsonResponse({'record': h.f['resource']});
        }
        h.elapsed += const Duration(milliseconds: 4000);
        return jsonResponse(h.f['snapshotOff']['response']);
      };
      await h.mount(tester, admin: false);
      expect(h.list!.snapshot, isNotNull);
      h.now = h.now.subtract(const Duration(days: 30));
      h.elapsed += const Duration(milliseconds: 1000);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(h.list!.snapshot, isNull);
      expect(h.list!.stale, isTrue);
      expect(h.requests.length, 2);
    },
  );
  testWidgets('response already expired during network is never displayed', (
    tester,
  ) async {
    final h = HaHarness();
    h.reply = (r) async {
      if (r.url.path.contains('/home-resources/')) {
        return jsonResponse({'record': h.f['resource']});
      }
      h.elapsed += const Duration(seconds: 6);
      return jsonResponse(h.f['snapshotOff']['response']);
    };
    await h.mount(tester, admin: false);
    expect(h.list!.stale, isTrue);
    expect(h.list!.snapshot, isNull);
  });
  testWidgets(
    'readout checks monotonic deadline before the timer callback runs',
    (tester) async {
      final h = HaHarness();
      await h.mount(tester, admin: false);
      expect(h.list!.snapshot, isNotNull);
      h.elapsed += const Duration(seconds: 6);
      expect(h.list!.snapshot, isNull);
      expect(h.list!.stale, isTrue);
      expect(h.requests.length, 2);
    },
  );
  testWidgets(
    'same-context pending refresh hides data and adopts verified new pair without cancelling context GET',
    (tester) async {
      final h = HaHarness();
      await h.mount(tester, admin: false);
      final c = h.list!;
      h.now = h.now.add(const Duration(minutes: 59, seconds: 40));
      final context = Completer<ServerContext>();
      h.auth.pendingContext = context;
      final refresh = c.refresh();
      await settle(tester);
      expect(h.account.hasPendingContext, isTrue);
      expect(c.snapshot, isNull);
      expect(c.record, isNull);
      expect(h.auth.refreshes, 1);
      context.complete(h.context);
      await refresh;
      await settle(tester);
      expect(h.account.failure, isNull);
      expect(c.snapshot, isNotNull);
      expect(h.requests.last.headers['authorization'], 'Bearer access-1');
    },
  );
  testWidgets(
    'higher ACL read remains a floor even when following snapshot fails',
    (tester) async {
      final h = HaHarness();
      await h.mount(tester, admin: false);
      final c = h.list!;
      (h.f['resource'] as Map)['aclRevision'] = 2;
      await c.refresh();
      expect(c.failure, 'invalid_response');
      expect(c.snapshot, isNull);
      final snapshots = h.requests
          .where((r) => r.url.path.endsWith('/snapshot'))
          .length;
      (h.f['resource'] as Map)['aclRevision'] = 1;
      await c.refresh();
      expect(c.failure, 'invalid_response');
      expect(c.record, isNull);
      expect(
        h.requests.where((r) => r.url.path.endsWith('/snapshot')).length,
        snapshots,
      );
    },
  );
  testWidgets(
    'admin preview cancel has no confirmation, confirm consumes once',
    (tester) async {
      final h = HaHarness();
      await h.mount(tester);
      final c = h.list!;
      expect(c.binding, isNull);
      expect(c.canPreview, isTrue);
      await c.prepare(
        c.services.single,
        'switch.synthetic',
        isCurrent: () => true,
      );
      final first = c.preview!;
      final cancel = c.cancel(first, isCurrent: () => true);
      expect(c.preview, isNull);
      await cancel;
      await c.confirm(first, isCurrent: () => true);
      expect(
        h.requests.where((r) => r.url.path.endsWith('/binding-confirm')),
        isEmpty,
      );
      await c.prepare(
        c.services.single,
        'switch.synthetic',
        isCurrent: () => true,
      );
      final second = c.preview!;
      await c.confirm(second, isCurrent: () => true);
      await c.confirm(second, isCurrent: () => true);
      expect(c.saved, isTrue);
      expect(c.binding, isNotNull);
      expect(
        h.requests.where((r) => r.url.path.endsWith('/binding-confirm')).length,
        1,
      );
    },
  );
  testWidgets(
    'expired preview cannot dispatch confirmation and requires fresh preview',
    (tester) async {
      final h = HaHarness();
      await h.mount(tester);
      final c = h.list!;
      await c.prepare(
        c.services.single,
        'switch.synthetic',
        isCurrent: () => true,
      );
      final old = c.preview!;
      h.elapsed += const Duration(seconds: 61);
      await c.confirm(old, isCurrent: () => true);
      expect(c.canConfirm, isFalse);
      expect(
        h.requests.where((r) => r.url.path.endsWith('/binding-confirm')),
        isEmpty,
      );
    },
  );
  testWidgets('expired preview is not exposed before its timer callback', (
    tester,
  ) async {
    final h = HaHarness();
    await h.mount(tester);
    final c = h.list!;
    await c.prepare(
      c.services.single,
      'switch.synthetic',
      isCurrent: () => true,
    );
    expect(c.preview, isNotNull);
    h.elapsed += const Duration(seconds: 61);
    expect(c.preview, isNull);
    expect(c.stale, isTrue);
  });
  testWidgets(
    'uncertain confirm is consumed, explicit GET recovers without write retry',
    (tester) async {
      final h = HaHarness();
      await h.mount(tester);
      final c = h.list!;
      await c.prepare(
        c.services.single,
        'switch.synthetic',
        isCurrent: () => true,
      );
      final preview = c.preview!;
      h.reply = (_) async => jsonResponse({
        'error': {'code': 'server_error'},
      }, 503);
      await c.confirm(preview, isCurrent: () => true);
      expect(c.uncertain, isTrue);
      expect(c.preview, isNull);
      expect(c.canPreview, isFalse);
      await c.confirm(preview, isCurrent: () => true);
      h.reply = null;
      h.bound = true;
      await c.refresh();
      expect(c.binding, isNotNull);
      expect(c.canPreview, isTrue);
      expect(
        h.requests.where((r) => r.url.path.endsWith('/binding-confirm')).length,
        1,
      );
    },
  );
  for (final loss in ['PIN', 'route', 'window', 'source', 'logout']) {
    for (final status in [200, 401]) {
      testWidgets(
        'late$status after $loss clears read and preserves unrelated current account',
        (tester) async {
          final h = HaHarness(), pending = Completer<http.Response>();
          h.reply = (r) => r.url.path.contains('/home-resources/')
              ? Future.value(jsonResponse({'record': h.f['resource']}))
              : pending.future;
          await h.mount(tester, admin: false);
          expect(h.requests.length, 2);
          if (loss == 'PIN') h.pin = false;
          if (loss == 'route') h.route = false;
          if (loss == 'window') h.interaction.setActive(false);
          if (loss == 'source') await h.home.choose(HomeSource.directLocal);
          if (loss == 'logout') await h.account.signOut();
          h.owner.synchronize();
          pending.complete(
            jsonResponse(
              status == 200
                  ? h.f['snapshotOff']['response']
                  : {
                      'error': {'code': 'unauthorized'},
                    },
              status,
            ),
          );
          await settle(tester);
          expect(h.list!.snapshot, isNull);
          expect(h.list!.record, isNull);
          expect(h.account.session == null, loss == 'logout');
          expect(h.store.value == null, loss == 'logout');
        },
      );
    }
  }
  testWidgets('current Core401 rejects account; upstream502 preserves it', (
    tester,
  ) async {
    final h = HaHarness()..snapshotStep = 'upstreamUnauthorized';
    await h.mount(tester, admin: false);
    expect(h.list!.failure, 'ha_upstream_unauthorized');
    expect(h.account.session, isNotNull);
    h.snapshotStep = 'coreUnauthorized';
    await h.list!.refresh();
    await settle(tester);
    expect(h.account.session, isNull);
    expect(h.store.value, isNull);
  });
  for (final status in [200, 401]) {
    testWidgets(
      'confirm late$status beyond previewTTL retains account and exposes uncertain GET recovery',
      (tester) async {
        final h = HaHarness();
        await h.mount(tester);
        final c = h.list!;
        await c.prepare(
          c.services.single,
          'switch.synthetic',
          isCurrent: () => true,
        );
        final value = c.preview!, pending = Completer<http.Response>();
        h.reply = (_) => pending.future;
        final future = c.confirm(value, isCurrent: () => true);
        await settle(tester);
        h.elapsed += const Duration(seconds: 61);
        pending.complete(
          jsonResponse(
            status == 200
                ? {'binding': h.f['preview']['response']['preview']['binding']}
                : {
                    'error': {'code': 'unauthorized'},
                  },
            status,
          ),
        );
        await future;
        expect(c.uncertain, isTrue);
        expect(c.preview, isNull);
        expect(c.canPreview, isFalse);
        expect(h.account.session, isNotNull);
        expect(h.store.value, isNotNull);
        expect(
          h.requests
              .where((r) => r.url.path.endsWith('/binding-confirm'))
              .length,
          1,
        );
      },
    );
  }
  for (final denied in ['direct', 'memberAdmin', 'password']) {
    testWidgets('$denied performs zero feature HTTP', (tester) async {
      final h = HaHarness();
      if (denied == 'direct') h.source.value = HomeSource.directLocal;
      if (denied == 'memberAdmin') h.role = ServerRole.member;
      if (denied == 'password') h.mustChangePassword = true;
      await h.mount(tester);
      await h.list!.refresh();
      expect(h.requests, isEmpty);
      expect(h.transports, 0);
    });
  }
}
