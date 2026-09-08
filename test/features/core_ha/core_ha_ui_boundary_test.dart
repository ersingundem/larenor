import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/core_ha/presentation/core_ha_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'core_ha_ui_fixture.dart';
import 'core_ha_ui_test.dart'
    show key, press, reveal, openSnapshot, openBinding;

VoidCallback held(WidgetTester tester, String value) {
  final root = key(value),
      native = find.descendant(
        of: root,
        matching: find.byType(CupertinoButton),
      );
  return tester
      .widget<CupertinoButton>(native.evaluate().isEmpty ? root : native)
      .onPressed!;
}

Future<void> preview(WidgetTester tester, HaUiHarness h) async {
  await press(tester, 'core-ha-service-${h.f['preview']['body']['serviceId']}');
  await tester.enterText(key('core-ha-entity'), 'switch.synthetic');
  await press(tester, 'core-ha-preview');
}

void main() {
  for (final loss in ['focus', 'pip', 'loading', 'error']) {
    testWidgets(
      'held resource entry under $loss opens no adapter route or HTTP',
      (tester) async {
        final h = HaUiHarness();
        await h.mount(tester);
        await h.signIn();
        await flush(tester);
        final id = 'core-ha-open-${h.f['resource']['ref']['id']}';
        await reveal(tester, key(id));
        final old = held(tester, id);
        if (loss == 'loading') {
          h.runtime(tester).invalidate(windowPolicySnapshotProvider);
        } else if (loss == 'error') {
          h.window.addError(StateError('private-window'));
        } else {
          h.window.add(
            WindowPolicySnapshot(
              supported: true,
              isResumed: true,
              hasWindowFocus: loss != 'focus',
              isPictureInPicture: loss == 'pip',
              reason: WindowRestrictionReason.noFocus,
            ),
          );
        }
        if (loss != 'loading') await flush(tester);
        old();
        await flush(tester);
        expect(find.byType(CoreHaScreen), findsNothing);
        expect(h.adapterRequests, isEmpty);
        expect(h.haReads, 0);
      },
    );
  }
  testWidgets(
    'real member route cover clears state, old refresh stays retired and pop reads fresh',
    (tester) async {
      final h = HaUiHarness()..role = 'member';
      await openSnapshot(tester, h);
      final old = held(tester, 'core-ha-refresh'),
          nav = Navigator.of(tester.element(key('core-ha-snapshot')));
      unawaited(
        nav.push(
          CupertinoPageRoute<void>(
            builder: (_) => const CupertinoPageScaffold(child: Text('Cover')),
          ),
        ),
      );
      await flush(tester);
      old();
      await flush(tester);
      expect(key('core-ha-state-off'), findsNothing);
      expect(h.snapshotReads, 1);
      nav.pop();
      await flush(tester);
      old();
      await flush(tester);
      expect(h.snapshotReads, 2);
      expect(key('core-ha-state-off'), findsOneWidget);
      expect(h.haReads, 0);
    },
  );
  testWidgets('native Enter and Space refresh each dispatch one GET sequence', (
    tester,
  ) async {
    final h = HaUiHarness();
    await openSnapshot(tester, h);
    Focus.of(
      tester.element(
        find.descendant(
          of: key('core-ha-refresh'),
          matching: find.byType(Text),
        ),
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await flush(tester);
    expect(h.snapshotReads, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await flush(tester);
    expect(h.snapshotReads, 3);
    expect(h.adapterRequests.every((r) => r.method == 'GET'), isTrue);
  });
  for (final pending in [false, true]) {
    for (final loss in [
      'window',
      'native',
      'background',
      'source',
      'logout',
      'role',
      'pin-loading',
      'pin-rotation',
      'root-route',
    ]) {
      testWidgets(
        '$loss retires actual binding ${pending ? 'late401' : 'held confirm'} and fields',
        (tester) async {
          final h = HaUiHarness();
          await openBinding(tester, h);
          await preview(tester, h);
          final old = held(tester, 'core-ha-confirm'),
              late = Completer<http.Response>();
          if (pending) {
            h.pendingConfirm = late;
            await press(tester, 'core-ha-confirm');
          }
          switch (loss) {
            case 'window':
              h.window.add(
                const WindowPolicySnapshot(
                  supported: true,
                  isResumed: true,
                  hasWindowFocus: false,
                  reason: WindowRestrictionReason.noFocus,
                ),
              );
            case 'native':
              tester.binding.handleViewFocusChanged(
                ViewFocusEvent(
                  viewId: tester.view.viewId,
                  state: ViewFocusState.unfocused,
                  direction: ViewFocusDirection.undefined,
                ),
              );
            case 'background':
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
            case 'source':
              h.source.writeFails = true;
              await h.home(tester).choose(HomeSource.directLocal);
            case 'logout':
              await h.account.signOut();
            case 'role':
              h.role = 'member';
              h.now = h.account.session!.expiresAt;
              await h.account.ensureSession();
            case 'pin-loading':
              h.runtime(tester).invalidate(pinLockProvider);
            case 'pin-rotation':
              await h
                  .runtime(tester)
                  .read(pinLockProvider.notifier)
                  .setPin('5678');
            case 'root-route':
              unawaited(
                Navigator.of(
                  tester.element(key('core-ha-binding')),
                  rootNavigator: true,
                ).push(
                  CupertinoPageRoute<void>(
                    builder: (_) =>
                        const CupertinoPageScaffold(child: Text('Root cover')),
                  ),
                ),
              );
          }
          old();
          if (pending) {
            late.complete(
              h.json({
                'error': {'code': 'unauthorized'},
              }, 401),
            );
            h.pendingConfirm = null;
          }
          await flush(tester);
          expect(
            h.adapterRequests
                .where((r) => r.url.path.endsWith('/binding-confirm'))
                .length,
            pending ? 1 : 0,
          );
          expect(find.text('switch.synthetic'), findsNothing);
          expect(h.account.session == null, loss == 'logout');
          expect(h.store.value == null, loss == 'logout');
          expect(h.haReads, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'active snapshot401 rejects Core account and never falls back to Direct',
    (tester) async {
      final h = HaUiHarness()..snapshotStep = 'coreUnauthorized';
      await openSnapshot(tester, h);
      expect(h.account.session, isNull);
      expect(h.store.value, isNull);
      expect(h.source.value, HomeSource.verifiedCore);
      expect(h.haReads, 0);
    },
  );
}
