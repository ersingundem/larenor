import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/home_data_scope.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/home_scope/data/core_layout_archive_codec.dart';
import 'package:larenor/features/home_scope/domain/core_layout_archive.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';

import 'core_layout_archive_ui_fixture.dart';

const passphrase = 'synthetic room archive password';
final scope = HomeDataScope.fromJson({
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
  'userId': 'one',
});
CoreLayoutArchiveV1 archive({HomeDataScope? owner}) =>
    CoreLayoutArchiveV1.fromScopedLayout(
      scope: owner ?? scope,
      sourceRevision: 10,
      capturedAt: DateTime.utc(2026, 9, 6),
      layout: const DashboardLayout(
        rooms: [DashboardRoom(id: 'saved', name: 'Saved room')],
      ).toJson(),
    );
Future<void> cryptoWait(WidgetTester tester, Finder expected) async {
  for (var i = 0; i < 100 && expected.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await flush(tester);
    if (expected.evaluate().isEmpty &&
        find.byType(CupertinoActivityIndicator).evaluate().isEmpty) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 300));
      await flush(tester);
    }
  }
  expect(expected, findsOneWidget);
}

Future<void> importArchive(
  WidgetTester tester,
  ArchiveHarness h,
  Uint8List bytes, {
  String password = passphrase,
  bool preview = true,
}) async {
  h.files.input = bytes;
  await archivePress(tester, 'core-layout-archive-pick');
  await archiveVisible(tester, 'core-layout-archive-open-password');
  await tester.enterText(
    find.byKey(const ValueKey('core-layout-archive-open-password')),
    password,
  );
  await archivePress(tester, 'core-layout-archive-decrypt');
  await cryptoWait(
    tester,
    find.byKey(
      ValueKey(
        preview ? 'core-layout-archive-preview' : 'core-layout-archive-message',
      ),
    ),
  );
}

void main() {
  late Uint8List encrypted, foreign;
  setUpAll(() async {
    const codec = CoreLayoutArchiveCodec();
    encrypted = await codec.encrypt(archive(), passphrase);
    foreign = await codec.encrypt(
      archive(
        owner: HomeDataScope.fromJson({
          'coreId': 'a' * 32,
          'homeId': 'c' * 32,
          'userId': 'one',
        }),
      ),
      passphrase,
    );
  });
  testWidgets(
    'actual Settings PIN opens Core archive and current scoped rooms',
    (tester) async {
      final h = ArchiveHarness();
      await h.mount(tester);
      await h.repository.save(
        const DashboardLayout(
          rooms: [DashboardRoom(id: 'current', name: 'Current room')],
        ),
      );
      expect(
        find.byKey(const ValueKey('core-layout-archive-entry')),
        findsNothing,
      );
      await h.open(tester);
      expect(
        find.byKey(const ValueKey('core-layout-archive-screen')),
        findsOneWidget,
      );
      expect(find.text('Current room'), findsOneWidget);
      expect(h.session.connectionReads, 0);
      expect(h.files.picks, 0);
      expect(h.files.saves, 0);
    },
  );
  testWidgets(
    'cancelled native import clears password and makes no scope write',
    (tester) async {
      final h = ArchiveHarness();
      await h.mount(tester);
      await h.open(tester);
      final before = await h.repository.readSnapshot();
      await archivePress(tester, 'core-layout-archive-pick');
      expect(h.files.picks, 1);
      expect(find.text('File selection cancelled.'), findsOneWidget);
      expect((await h.repository.readSnapshot()).revision, before.revision);
    },
  );
  testWidgets(
    'real codec export writes ciphertext and clears both password fields',
    (tester) async {
      final h = ArchiveHarness();
      await h.mount(tester);
      await h.repository.save(
        const DashboardLayout(
          rooms: [DashboardRoom(id: 'current', name: 'Current room')],
        ),
      );
      await h.open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('core-layout-archive-password')),
        passphrase,
      );
      await tester.enterText(
        find.byKey(const ValueKey('core-layout-archive-repeat')),
        passphrase,
      );
      await archivePress(tester, 'core-layout-archive-export');
      await cryptoWait(tester, find.text('Encrypted room archive saved.'));
      expect(h.files.saves, 1);
      expect(h.files.output, isNotNull);
      final decoded = await tester.runAsync(
        () =>
            const CoreLayoutArchiveCodec().decrypt(h.files.output!, passphrase),
      );
      expect(decoded!.rooms.single.name, 'Current room');
      expect(decoded.matchesScope(scope), isTrue);
      for (final key in [
        'core-layout-archive-password',
        'core-layout-archive-repeat',
      ]) {
        expect(
          tester
              .widget<CupertinoTextField>(find.byKey(ValueKey(key)))
              .controller!
              .text,
          isEmpty,
        );
      }
    },
  );
  testWidgets(
    'actual preview cancel then replace writes only scope key and reopen reads it',
    (tester) async {
      final h = ArchiveHarness();
      await h.mount(tester);
      await h.repository.save(
        const DashboardLayout(
          rooms: [DashboardRoom(id: 'current', name: 'Current room')],
        ),
      );
      await h.open(tester);
      await importArchive(tester, h, encrypted);
      expect(find.text('Current room'), findsWidgets);
      expect(find.text('Saved room'), findsOneWidget);
      await archivePress(tester, 'core-layout-archive-replace');
      await archivePress(tester, 'core-layout-archive-confirm-cancel');
      expect((await h.repository.load()).rooms.single.id, 'current');
      await archivePress(tester, 'core-layout-archive-replace');
      final confirm = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('core-layout-archive-confirm')),
          )
          .onPressed!;
      confirm();
      confirm();
      await flush(tester);
      expect(find.text('Room layout replaced and verified.'), findsOneWidget);
      final stored = await h.repository.readSnapshot();
      expect(stored.revision, 2);
      expect(stored.layout.rooms.single.id, 'saved');
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getString('dashboard_layout'), 'legacy-private');
      expect(prefs.getString('unrelated'), 'unchanged');
      expect(
        prefs.getKeys().where(
          (key) => key.startsWith('dashboard_layout_core_v1_'),
        ),
        [scope.storageKey],
      );
      await archivePress(tester, 'core-layout-archive-back');
      await archivePress(tester, 'core-layout-archive-entry');
      expect(find.text('Saved room'), findsOneWidget);
    },
  );
  for (final kind in ['wrong-password', 'cross-home']) {
    testWidgets('$kind leaves target unchanged and no replace confirmation', (
      tester,
    ) async {
      final h = ArchiveHarness();
      await h.mount(tester);
      await h.open(tester);
      await importArchive(
        tester,
        h,
        kind == 'cross-home' ? foreign : encrypted,
        password: kind == 'wrong-password'
            ? 'another incorrect password'
            : passphrase,
        preview: false,
      );
      expect(
        find.byKey(const ValueKey('core-layout-archive-replace')),
        findsNothing,
      );
      expect((await h.repository.readSnapshot()).revision, 0);
    });
  }
  testWidgets('target changed during confirmation is never overwritten', (
    tester,
  ) async {
    final h = ArchiveHarness();
    await h.mount(tester);
    await h.open(tester);
    await importArchive(tester, h, encrypted);
    await archivePress(tester, 'core-layout-archive-replace');
    await h.repository.save(
      const DashboardLayout(
        rooms: [DashboardRoom(id: 'third', name: 'Third room')],
      ),
    );
    await archivePress(tester, 'core-layout-archive-confirm');
    expect((await h.repository.load()).rooms.single.id, 'third');
    expect(find.text('Room layout replaced and verified.'), findsNothing);
  });
  for (final change in [
    'logout',
    'source-roundtrip',
    'pin-roundtrip',
    'pin-loading',
    'root-route',
    'native-focus',
    'background',
    'idle',
    'expiry',
  ]) {
    testWidgets('held confirmation cannot write after $change', (tester) async {
      final h = ArchiveHarness();
      await h.mount(tester);
      await h.open(tester);
      await importArchive(tester, h, encrypted);
      await archivePress(tester, 'core-layout-archive-replace');
      final held = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('core-layout-archive-confirm')),
          )
          .onPressed!;
      switch (change) {
        case 'logout':
          await h.session.account.signOut();
        case 'source-roundtrip':
          await h.home.choose(HomeSource.directLocal);
          await h.home.choose(HomeSource.verifiedCore);
          h.home.runtimeMounted(h.home.runtimeIdentity);
        case 'pin-roundtrip':
          await h.container.read(pinLockProvider.notifier).setPin('5678');
          await h.container.read(pinLockProvider.notifier).setPin('1234');
        case 'pin-loading':
          h.container.invalidate(pinLockProvider);
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
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        case 'idle':
          h.home.interaction.setActive(false);
          h.home.interaction.setActive(true);
        case 'expiry':
          h.session.now = h.session.now.add(const Duration(minutes: 6));
      }
      // Invoke before rebuilding, where possible, to test the action guard itself.
      held();
      await flush(tester);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getString(scope.storageKey), isNull);
      expect(find.text('Room layout replaced and verified.'), findsNothing);
    });
  }
  testWidgets(
    'native picker background requires PIN again and fresh same-home preview',
    (tester) async {
      final h = ArchiveHarness();
      await h.mount(tester);
      await h.open(tester);
      final pending = Completer<Uint8List?>();
      h.files.onPick = () => pending.future;
      await archivePress(tester, 'core-layout-archive-pick');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await flush(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      pending.complete(encrypted);
      await flush(tester);
      expect(find.byKey(const ValueKey('backup-reauth-pin')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('backup-reauth-pin')),
        '1234',
      );
      await tester.tap(find.text('Unlock').last);
      await flush(tester);
      await tester.enterText(
        find.byKey(const ValueKey('core-layout-archive-open-password')),
        passphrase,
      );
      await archivePress(tester, 'core-layout-archive-decrypt');
      await cryptoWait(
        tester,
        find.byKey(const ValueKey('core-layout-archive-preview')),
      );
      expect((await h.repository.readSnapshot()).revision, 0);
    },
  );
  testWidgets(
    'same source PIN rotation during picker cannot revive ciphertext',
    (tester) async {
      final h = ArchiveHarness();
      await h.mount(tester);
      await h.open(tester);
      final pending = Completer<Uint8List?>();
      h.files.onPick = () => pending.future;
      await archivePress(tester, 'core-layout-archive-pick');
      await h.container.read(pinLockProvider.notifier).setPin('5678');
      await h.container.read(pinLockProvider.notifier).setPin('1234');
      pending.complete(encrypted);
      await flush(tester);
      expect(
        find.byKey(const ValueKey('core-layout-archive-decrypt')),
        findsNothing,
      );
      expect((await h.repository.readSnapshot()).revision, 0);
    },
  );
  for (final change in ['source', 'logout', 'root-route', 'expiry']) {
    testWidgets(
      'late native file result after $change cannot produce preview',
      (tester) async {
        final h = ArchiveHarness();
        await h.mount(tester);
        await h.open(tester);
        final pending = Completer<Uint8List?>();
        h.files.onPick = () => pending.future;
        await archivePress(tester, 'core-layout-archive-pick');
        switch (change) {
          case 'source':
            await h.home.choose(HomeSource.directLocal);
            await h.home.choose(HomeSource.verifiedCore);
            h.home.runtimeMounted(h.home.runtimeIdentity);
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
          case 'expiry':
            h.session.now = h.session.now.add(const Duration(minutes: 6));
        }
        pending.complete(encrypted);
        await flush(tester);
        expect(
          find.byKey(const ValueKey('core-layout-archive-decrypt')),
          findsNothing,
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect(prefs.getString(scope.storageKey), isNull);
      },
    );
  }
  for (final values in [
    ('too short', 'too short'),
    (passphrase, 'different confirmation'),
  ]) {
    testWidgets('invalid export password $values never dispatches file save', (
      tester,
    ) async {
      final h = ArchiveHarness();
      await h.mount(tester);
      await h.open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('core-layout-archive-password')),
        values.$1,
      );
      await tester.enterText(
        find.byKey(const ValueKey('core-layout-archive-repeat')),
        values.$2,
      );
      await archivePress(tester, 'core-layout-archive-export');
      expect(h.files.saves, 0);
      expect(
        find.byKey(const ValueKey('core-layout-archive-message')),
        findsOneWidget,
      );
    });
  }
}
