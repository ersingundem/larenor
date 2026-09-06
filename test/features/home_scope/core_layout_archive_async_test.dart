import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/home_scope/data/core_layout_archive_codec.dart';

import 'core_layout_archive_ui_fixture.dart';
import 'core_layout_archive_screen_test.dart'
    show scope, passphrase, archive, importArchive;

class _PendingPin extends PinLockStore {
  Completer<String?>? pending;
  @override
  Future<String?> read() => pending?.future ?? super.read();
}

void main() {
  for (final change in ['logout', 'root-route', 'native-focus', 'dispose']) {
    testWidgets(
      'retirement during awaited durable PIN read cannot start export after $change',
      (tester) async {
        final h = ArchiveHarness(), pin = _PendingPin();
        await h.mount(tester, pinStore: pin);
        await h.open(tester);
        await tester.enterText(
          find.byKey(const ValueKey('core-layout-archive-password')),
          passphrase,
        );
        await tester.enterText(
          find.byKey(const ValueKey('core-layout-archive-repeat')),
          passphrase,
        );
        pin.pending = Completer<String?>();
        await archivePress(tester, 'core-layout-archive-export');
        switch (change) {
          case 'logout':
            await h.session.account.signOut();
          case 'root-route':
            unawaited(
              h.navigator.currentState!.push(
                CupertinoPageRoute<void>(
                  builder: (_) => const Text('Root overlay'),
                ),
              ),
            );
          case 'native-focus':
            tester.binding.handleViewFocusChanged(
              ViewFocusEvent(
                viewId: tester.view.viewId,
                state: ViewFocusState.unfocused,
                direction: ViewFocusDirection.undefined,
              ),
            );
          case 'dispose':
            await archivePress(tester, 'core-layout-archive-back');
        }
        pin.pending!.complete('1234');
        await flush(tester);
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect(prefs.getString(scope.storageKey), isNull);
        expect(h.files.saves, 0);
        expect(find.text(passphrase), findsNothing);
      },
    );
  }
  for (final change in ['root-route', 'native-focus', 'window-loading']) {
    testWidgets(
      'retained Back after $change cannot pop archive or unrelated overlay',
      (tester) async {
        final h = ArchiveHarness();
        await h.mount(tester);
        await h.open(tester);
        final held = tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('core-layout-archive-back')),
            )
            .onPressed!;
        switch (change) {
          case 'root-route':
            unawaited(
              h.navigator.currentState!.push(
                CupertinoPageRoute<void>(
                  builder: (_) => const Text('Root overlay'),
                ),
              ),
            );
          case 'native-focus':
            tester.binding.handleViewFocusChanged(
              ViewFocusEvent(
                viewId: tester.view.viewId,
                state: ViewFocusState.unfocused,
                direction: ViewFocusDirection.undefined,
              ),
            );
          case 'window-loading':
            h.container.invalidate(windowPolicySnapshotProvider);
        }
        held();
        await flush(tester);
        expect(
          find.byKey(
            const ValueKey('core-layout-archive-screen'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        if (change == 'root-route') {
          expect(find.text('Root overlay'), findsOneWidget);
        }
      },
    );
  }
  testWidgets('retained Back cannot dismiss the archive confirmation', (
    tester,
  ) async {
    final h = ArchiveHarness();
    await h.mount(tester);
    await h.open(tester);
    final held = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('core-layout-archive-back')),
        )
        .onPressed!;
    final encrypted = await tester.runAsync(
      () => const CoreLayoutArchiveCodec().encrypt(archive(), passphrase),
    );
    await importArchive(tester, h, encrypted!);
    await archivePress(tester, 'core-layout-archive-replace');
    held();
    await flush(tester);
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('core-layout-archive-screen'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(prefs.getString(scope.storageKey), isNull);
    await tester.tap(
      find.byKey(const ValueKey('core-layout-archive-confirm-cancel')),
    );
    await flush(tester);
  });
  testWidgets('fresh Back can leave an expired archive', (tester) async {
    final h = ArchiveHarness();
    await h.mount(tester);
    await h.open(tester);
    await tester.pump(const Duration(minutes: 5));
    await flush(tester);
    await archivePress(tester, 'core-layout-archive-back');
    expect(
      find.byKey(const ValueKey('core-layout-archive-screen')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('core-layout-archive-entry')),
      findsOneWidget,
    );
  });
}
