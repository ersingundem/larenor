import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/window/window_policy_models.dart';

import '../../core/home_scope_fixture.dart' show flush, press;
import 'home_resources_fixture.dart';

Finder key(String name) => find.byKey(ValueKey(name));
VoidCallback refreshCallback(WidgetTester tester) =>
    tester.widget<CupertinoButton>(key('home-resources-refresh')).onPressed!;

void main() {
  testWidgets(
    'refresh clears stale ACL data immediately, single flight and safe explicit retry',
    (tester) async {
      final h = ResourceHarness();
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      h.pending = Completer<http.Response>();
      final callback = refreshCallback(tester);
      callback();
      callback();
      await flush(tester);
      expect(find.text('Salon'), findsNothing);
      expect(key('home-resources-loading'), findsOneWidget);
      expect(h.resourceReads, 2);
      h.pending!.complete(
        h.json({
          'error': {'code': 'private-value'},
        }, 503),
      );
      h.pending = null;
      await flush(tester);
      expect(key('home-resources-error'), findsOneWidget);
      expect(find.textContaining('private-value'), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(h.resourceReads, 2);
      h.response = h.fixture['revokedList'];
      await press(tester, 'home-resources-refresh');
      expect(find.text('Salon'), findsNothing);
      expect(find.text('Okuma lambası'), findsOneWidget);
      expect(h.authPosts, 1);
      expect(h.haReads, 0);
    },
  );
  testWidgets(
    'snapshot conflict clears the full page sequence and refresh restarts without cursor',
    (tester) async {
      final h = ResourceHarness()..response = contract()['firstPage'];
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      expect(key('home-resources-load-more'), findsOneWidget);
      h.status = 409;
      h.response = h.fixture['stalePageError'];
      await press(tester, 'home-resources-load-more');
      expect(find.text('Salon'), findsNothing);
      expect(key('home-resources-error'), findsOneWidget);
      expect(key('home-resources-load-more'), findsNothing);
      expect(
        h.requests.last.url.queryParameters['after'],
        h.fixture['firstPage']['nextAfter'],
      );
      h.status = 200;
      h.response = h.fixture['memberList'];
      await press(tester, 'home-resources-refresh');
      expect(h.requests.last.url.queryParameters, {'limit': '25'});
      expect(find.text('Salon'), findsOneWidget);
    },
  );
  for (final cause in [
    'background',
    'window',
    'route',
    'logout',
    'user',
    'home',
  ]) {
    testWidgets(
      '$cause retires delayed reads and old callbacks without cancelling auth',
      (tester) async {
        final h = ResourceHarness();
        await h.mount(tester);
        await h.signIn();
        await flush(tester);
        final callback = refreshCallback(tester);
        final delayed = Completer<http.Response>();
        h.pending = delayed;
        callback();
        await flush(tester);
        expect(h.resourceReads, 2);
        h.pending = null;
        switch (cause) {
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
          case 'window':
            h.window.add(
              const WindowPolicySnapshot(
                supported: true,
                isResumed: true,
                hasWindowFocus: false,
                reason: WindowRestrictionReason.noFocus,
              ),
            );
          case 'route':
            unawaited(h.router(tester).push('/settings'));
          case 'logout':
            await h.account.signOut();
          case 'user':
            await h.account.signOut();
            h.userId = '8' * 32;
            h.response = h.fixture['emptyList'];
            await h.signIn();
          case 'home':
            await h.account.signOut();
            h.contextResponse = h.fixture['otherContextList']['scope'];
            h.response = contract()['otherContextList'];
            await h.signIn();
        }
        await flush(tester);
        final requestsAfterLoss = h.resourceReads;
        callback();
        delayed.complete(h.json(h.fixture['memberList']));
        await flush(tester);
        expect(find.text('Salon'), findsNothing);
        if (cause == 'home') expect(find.text('İkinci ev · Salon'), findsOneWidget);
        expect(h.resourceReads, requestsAfterLoss);
        expect(h.closed, greaterThanOrEqualTo(2));
        expect(h.haReads, 0);
        if (cause == 'background' || cause == 'window' || cause == 'route') {
          expect(h.account.session, isNotNull);
          expect(h.account.hasPendingContext, isFalse);
          h.response = h.fixture['revokedList'];
          if (cause == 'background')
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          if (cause == 'window')
            h.window.add(
              const WindowPolicySnapshot(
                supported: true,
                isResumed: true,
                hasWindowFocus: true,
                reason: WindowRestrictionReason.none,
              ),
            );
          if (cause == 'route') h.router(tester).pop();
          await flush(tester);
          expect(find.text('Okuma lambası'), findsOneWidget);
          callback();
          await flush(tester);
          expect(h.resourceReads, requestsAfterLoss + 1);
          await press(tester, 'home-resources-refresh');
          expect(h.resourceReads, requestsAfterLoss + 2);
        }
      },
    );
  }
  testWidgets(
    'expiry hides metadata during delayed read; explicit refresh keeps its pending context GET alive',
    (tester) async {
      final h = ResourceHarness();
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      final delayed = Completer<http.Response>();
      h.pending = delayed;
      await press(tester, 'home-resources-refresh');
      final untilExpiry = h.account.session!.expiresAt
          .subtract(const Duration(seconds: 30))
          .difference(h.now);
      h.now = h.now.add(untilExpiry);
      await tester.pump(untilExpiry);
      await flush(tester);
      expect(find.text('Salon'), findsNothing);
      expect(key('home-resources-loading'), findsNothing);
      final count = h.resourceReads;
      h.pending = null;
      delayed.complete(h.json(h.fixture['memberList']));
      await flush(tester);
      expect(h.resourceReads, count);
      h.pendingContext = Completer<http.Response>();
      await press(tester, 'home-resources-refresh');
      expect(h.account.hasPendingContext, isTrue);
      expect(h.refreshes, 1);
      expect(h.resourceReads, count);
      h.pendingContext!.complete(h.json(h.contextResponse));
      h.pendingContext = null;
      await flush(tester);
      expect(h.account.context, isNotNull);
      expect(h.account.failure, isNull);
      expect(find.text('Salon'), findsOneWidget);
      expect(h.resourceReads, count + 1);
      expect(h.refreshes, 1);
      expect(h.haReads, 0);
    },
  );
  testWidgets('native focus is view-specific and old callbacks stay retired after focus returns', (tester) async {
    final h = ResourceHarness(); await h.mount(tester); await h.signIn(); await flush(tester);
    final callback = refreshCallback(tester);
    void focus(int id, ViewFocusState state) => tester.binding.handleViewFocusChanged(ViewFocusEvent(viewId:id,state:state,direction:ViewFocusDirection.undefined));
    focus(tester.view.viewId + 1, ViewFocusState.unfocused); await flush(tester);
    expect(find.text('Salon'), findsOneWidget);
    focus(tester.view.viewId, ViewFocusState.unfocused); await flush(tester);
    expect(find.text('Salon'), findsNothing); callback(); expect(h.resourceReads, 1);
    focus(tester.view.viewId, ViewFocusState.focused); await flush(tester);
    expect(find.text('Salon'), findsOneWidget); callback(); await flush(tester); expect(h.resourceReads, 2);
  });
  testWidgets('unknown and picture-in-picture clear reads, focused external display and unsupported host remain usable', (tester) async {
    final h = ResourceHarness(); await h.mount(tester); await h.signIn(); await flush(tester);
    for (final snapshot in [WindowPolicySnapshot.unknown, const WindowPolicySnapshot(supported:true,isResumed:true,hasWindowFocus:true,isPictureInPicture:true)]) {
      h.window.add(snapshot); await flush(tester); expect(find.text('Salon'), findsNothing);
      h.window.add(const WindowPolicySnapshot(supported:true,isResumed:true,hasWindowFocus:true,isExternalDisplay:true,reason:WindowRestrictionReason.externalDisplay)); await flush(tester);
      expect(find.text('Salon'), findsOneWidget);
    }
    h.window.add(const WindowPolicySnapshot(supported:false)); await flush(tester);
    await press(tester, 'home-resources-refresh'); expect(find.text('Salon'), findsOneWidget); expect(h.haReads, 0);
  });

}
