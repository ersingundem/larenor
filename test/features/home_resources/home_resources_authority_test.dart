import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/server/presentation/server_connection_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../../core/home_scope_fixture.dart' show flush, press, ScopeHarness;
import 'home_resources_fixture.dart';

Finder key(String value) => find.byKey(ValueKey(value));
void main() {
  testWidgets(
    'PIN account recovery finishes actual pending login before Core list mounts',
    (tester) async {
      final h = ResourceHarness();
      await h.mount(tester, pin: '1234');
      unawaited(h.router(tester).push('/settings'));
      await flush(tester);
      expect(find.byType(ServerConnectionScreen), findsNothing);
      expect(h.resourceReads, 0);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await flush(tester);
      expect(find.byType(ServerConnectionScreen), findsOneWidget);
      for (final field in {
        'server-url': 'https://synthetic.invalid',
        'server-username': 'fixture',
        'server-password': 'synthetic',
      }.entries) {
        await tester.enterText(key(field.key), field.value);
      }
      h.pendingContext = Completer<http.Response>();
      await press(tester, 'server-sign-in');
      expect(h.account.hasPendingContext, isTrue);
      expect(h.resourceReads, 0);
      h.pendingContext!.complete(h.json(h.contextResponse));
      h.pendingContext = null;
      await flush(tester);
      expect(h.account.failure, isNull);
      expect(h.account.context, isNotNull);
      expect(find.text('Salon'), findsOneWidget);
      expect(h.authPosts, 1);
      expect(h.haReads, 0);
      final l10n = AppLocalizations.of(
        tester.element(key('home-resources-refresh')),
      );
      final manage = find.text(l10n.homeCoreManageAccount);
      await tester.ensureVisible(manage);
      await tester.tap(manage);
      await flush(tester);
      expect(find.byType(ServerConnectionScreen), findsNothing);
      expect(find.text('Salon'), findsNothing);
      expect(find.byType(CupertinoTextField), findsOneWidget);
    },
  );
  testWidgets(
    'same-context token rotation keeps router and ignores old read 401',
    (tester) async {
      final h = ResourceHarness();
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      final router = h.router(tester),
          previousToken = h.account.session!.accessToken;
      final late = Completer<http.Response>();
      h.pending = late;
      await press(tester, 'home-resources-refresh');
      h.pending = null;
      h.now = h.account.session!.expiresAt;
      h.pendingContext = Completer<http.Response>();
      final refresh = h.account.ensureSession();
      await flush(tester);
      expect(h.account.hasPendingContext, isTrue);
      expect(find.text('Salon'), findsNothing);
      h.pendingContext!.complete(h.json(h.contextResponse));
      h.pendingContext = null;
      await refresh;
      await flush(tester);
      final currentToken = h.account.session!.accessToken;
      expect(currentToken, isNot(previousToken));
      expect(h.router(tester), same(router));
      late.complete(
        h.json({
          'error': {'code': 'unauthorized'},
        }, 401),
      );
      await flush(tester);
      expect(h.account.session!.accessToken, currentToken);
      expect(find.text('Salon'), findsOneWidget);
      expect(h.refreshes, 1);
      expect(h.haReads, 0);
    },
  );
  for (final loss in ['route', 'background']) {
    testWidgets(
      'retired $loss read 401 cannot clear the unchanged account token',
      (tester) async {
        final h = ResourceHarness();
        await h.mount(tester);
        await h.signIn();
        await flush(tester);
        final session = h.account.session;
        final delayed = Completer<http.Response>();
        h.pending = delayed;
        await press(tester, 'home-resources-refresh');
        h.pending = null;
        if (loss == 'route') {
          unawaited(h.router(tester).push('/settings'));
        } else {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        }
        await flush(tester);
        delayed.complete(
          h.json({
            'error': {'code': 'unauthorized'},
          }, 401),
        );
        await flush(tester);
        expect(h.account.session, same(session));
        expect(h.store.value?.accessToken, session!.accessToken);
        expect(find.text('Salon'), findsNothing);
        expect(h.haReads, 0);
      },
    );
  }
  testWidgets('current visible read 401 still rejects the current account', (
    tester,
  ) async {
    final h = ResourceHarness();
    await h.mount(tester);
    await h.signIn();
    await flush(tester);
    h.status = 401;
    h.response = {
      'error': {'code': 'unauthorized'},
    };
    await press(tester, 'home-resources-refresh');
    expect(h.account.session, isNull);
    expect(h.store.value, isNull);
    expect(find.text('Salon'), findsNothing);
    expect(h.haReads, 0);
  });
  testWidgets('idle clears metadata and waking invalidates captured refresh', (
    tester,
  ) async {
    final h = ResourceHarness();
    await h.mount(
      tester,
      preferences: {'idle_mode_enabled': true, 'idle_timeout_minutes': 1},
    );
    await h.signIn();
    await flush(tester);
    final callback = tester
        .widget<CupertinoButton>(key('home-resources-refresh'))
        .onPressed!;
    await tester.pump(const Duration(minutes: 1));
    await flush(tester);
    expect(find.text('Salon'), findsNothing);
    callback();
    await flush(tester);
    expect(h.resourceReads, 1);
    await tester.tapAt(const Offset(300, 500));
    await flush(tester);
    expect(find.text('Salon'), findsOneWidget);
    callback();
    await flush(tester);
    expect(h.resourceReads, 2);
    await press(tester, 'home-resources-refresh');
    expect(h.resourceReads, 3);
  });
  testWidgets(
    'explicit source retirement discards delayed Core list and saved Core preference survives logout',
    (tester) async {
      final h = ResourceHarness();
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      final delayed = Completer<http.Response>();
      h.pending = delayed;
      await press(tester, 'home-resources-refresh');
      h.pending = null;
      final home = h.home(tester);
      h.source.writeFails = true;
      await home.choose(HomeSource.directLocal);
      await flush(tester);
      delayed.complete(h.json(h.fixture['memberList']));
      await flush(tester);
      expect(find.text('Salon'), findsNothing);
      expect(h.haReads, 0);
      expect(h.source.value, HomeSource.verifiedCore);
      await h.account.signOut();
      expect(h.source.value, HomeSource.verifiedCore);
    },
  );
  testWidgets(
    'bounded lazy history reaches the final permitted record beyond one hundred',
    (tester) async {
      final h = ResourceHarness();
      h.resourceResponse = (request) {
        final after = request.url.queryParameters['after'];
        final start = after == null ? 1 : int.parse(after, radix: 16) + 1;
        final end = (start + 24).clamp(1, 512);
        final records = <Object?>[];
        for (var id = start; id <= end; id++) {
          records.add({
            'ref': {
              ...h.fixture['context'] as Map,
              'kind': 'room',
              'id': id.toRadixString(16).padLeft(32, '0'),
            },
            'label': 'Permitted room $id',
            'order': id,
            'revision': 1,
            'aclRevision': 1,
            'permissions': {'read': true, 'write': false},
          });
        }
        return {
          'scope': h.fixture['context'],
          'entries': records,
          'snapshot': 'a' * 64,
          'nextAfter': end == 512
              ? null
              : end.toRadixString(16).padLeft(32, '0'),
        };
      };
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      for (var i = 0; i < 20; i++) {
        await tester.scrollUntilVisible(
          key('home-resources-load-more'),
          700,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 20,
        );
        await press(tester, 'home-resources-load-more');
      }
      await tester.scrollUntilVisible(
        find.text('Permitted room 512'),
        700,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 20,
      );
      expect(find.text('Permitted room 512'), findsOneWidget);
      expect(key('home-resources-load-more'), findsNothing);
      expect(h.resourceReads, 21);
      expect(h.haReads, 0);
      expect(find.byType(Text).evaluate().length, lessThan(100));
    },
  );
  testWidgets('Server login alone preserves the actual direct HA app route', (tester) async {
    final h = ScopeHarness(HomeSource.directLocal); await h.mount(tester);
    final router = h.router(tester), reads = h.connectionReads;
    await h.signIn(); await flush(tester);
    expect(h.router(tester), same(router)); expect(h.connectionReads, reads);
    expect(key('home-resources-list'), findsNothing);
    expect(h.home(tester).usesLocalHome, isTrue);
  });

}
