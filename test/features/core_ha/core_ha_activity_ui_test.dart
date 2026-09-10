import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/core_ha/data/core_ha_checkpoint_store.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'core_ha_ui_fixture.dart';

Finder keyed(String value) => find.byKey(ValueKey(value));

Future<void> reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    final scrollable = find
        .descendant(
          of: find.byType(CustomScrollView).last,
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      target,
      350,
      scrollable: scrollable,
      maxScrolls: 30,
    );
  }
  await tester.ensureVisible(target);
  await flush(tester);
}

Future<void> press(WidgetTester tester, String value) async {
  await reveal(tester, keyed(value));
  await tester.tap(keyed(value));
  await flush(tester);
}

Future<void> scrollToTop(WidgetTester tester) async {
  final scrollable = find
      .descendant(
        of: find.byType(CustomScrollView).last,
        matching: find.byType(Scrollable),
      )
      .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await flush(tester);
}

Future<void> authorizeCheckpoint(WidgetTester tester, String confirmKey) async {
  await reveal(tester, keyed('core-ha-checkpoint-reauth-pin'));
  await tester.enterText(keyed('core-ha-checkpoint-reauth-pin'), '1234');
  await press(tester, confirmKey);
}

Future<void> openSnapshotActivity(
  WidgetTester tester,
  HaUiHarness harness, {
  String locale = 'en',
  double width = 600,
  double scale = 1,
}) async {
  await harness.mount(tester, locale: locale, width: width, scale: scale);
  await harness.signIn();
  await flush(tester);
  await reveal(
    tester,
    keyed('home-resource-${harness.f['resource']['ref']['id']}'),
  );
  await press(tester, 'core-ha-open-${harness.f['resource']['ref']['id']}');
  await press(tester, 'core-ha-activity-open');
}

Future<void> openBindingActivity(
  WidgetTester tester,
  HaUiHarness harness,
) async {
  await harness.mount(tester, pin: '1234');
  await harness.signIn();
  await flush(tester);
  await press(tester, 'home-resources-manage');
  expect(find.byType(SettingsGateScreen), findsOneWidget);
  await tester.enterText(find.byType(CupertinoTextField), '1234');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await flush(tester);
  await reveal(
    tester,
    keyed('home-resource-edit-${harness.f['resource']['ref']['id']}'),
  );
  await press(tester, 'core-ha-bind-${harness.f['resource']['ref']['id']}');
  await press(tester, 'core-ha-activity-open');
}

void main() {
  testWidgets(
    'member activity exposes attribution and no admin integrity call',
    (tester) async {
      final harness = HaUiHarness()..role = 'member';
      await openSnapshotActivity(tester, harness);
      expect(keyed('core-ha-activity'), findsOneWidget);
      expect(keyed('core-ha-activity-entry-${'9' * 32}'), findsOneWidget);
      expect(find.text('Actor'), findsWidgets);
      expect(find.text('Core API'), findsWidgets);
      expect(find.text('Explicit command request'), findsWidgets);
      expect(find.text('Accepted'), findsWidgets);
      expect(find.text('Physical causality is not verified.'), findsWidgets);
      expect(
        find.text('Open the PIN-protected link settings to verify integrity.'),
        findsOneWidget,
      );
      expect(harness.historyReads, 1);
      expect(harness.integrityReads, 0);
      expect(
        harness.adapterRequests.every((request) => request.method == 'GET'),
        isTrue,
      );
      expect(harness.haReads, 0);
    },
  );

  testWidgets('PIN-protected admin compares an external checkpoint by GET', (
    tester,
  ) async {
    final harness = HaUiHarness();
    await openBindingActivity(tester, harness);
    expect(find.text('Core verified the local history chain.'), findsOneWidget);
    expect(
      find.text('No saved checkpoint was compared in this read.'),
      findsOneWidget,
    );
    await tester.enterText(
      keyed('core-ha-checkpoint-input'),
      'eyJjaGFpbiI6InN5bnRoZXRpYyJ9.fixture',
    );
    await press(tester, 'core-ha-checkpoint-verify');
    expect(
      find.text('The saved checkpoint matches this history chain.'),
      findsOneWidget,
    );
    expect(harness.integrityReads, 2);
    final requests = harness.adapterRequests.where(
      (request) => request.url.path.endsWith('/history/verification'),
    );
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(requests.last.url.queryParameters, {
      'checkpoint': 'eyJjaGFpbiI6InN5bnRoZXRpYyJ9.fixture',
    });
  });

  testWidgets(
    'admin explicitly pins, exports, automatically compares, and rotates',
    (tester) async {
      final harness = HaUiHarness();
      String? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await openBindingActivity(tester, harness);

      expect(keyed('core-ha-checkpoint-unpinned'), findsOneWidget);
      await press(tester, 'core-ha-checkpoint-pin');
      await authorizeCheckpoint(tester, 'core-ha-checkpoint-pin-confirm');
      expect(keyed('core-ha-checkpoint-pinned'), findsOneWidget);
      final storage = const FlutterSecureStorage();
      final storageKey = CoreHaCheckpointStore.storageKey(
        harness.account.session!.context!,
      );
      final firstRaw = await storage.read(key: storageKey);
      expect(firstRaw, contains(harness.integrityCheckpoint));

      await press(tester, 'core-ha-checkpoint-copy');
      await authorizeCheckpoint(tester, 'core-ha-checkpoint-copy-confirm');
      expect(clipboard, contains(harness.integrityCheckpoint));
      expect(keyed('core-ha-checkpoint-copied'), findsOneWidget);

      final firstCheckpoint = harness.integrityCheckpoint;
      harness
        ..integritySequence = 3
        ..integrityHead = 'c' * 64
        ..integrityCheckpoint = 'eyJjaGFpbiI6Im5leHQifQ.fixture';
      await scrollToTop(tester);
      await press(tester, 'core-ha-activity-refresh');
      expect(keyed('core-ha-checkpoint-auto-matched'), findsOneWidget);
      final comparisons = harness.adapterRequests.where(
        (request) =>
            request.url.path.endsWith('/history/verification') &&
            request.url.queryParameters.containsKey('checkpoint'),
      );
      expect(
        comparisons.last.url.queryParameters['checkpoint'],
        firstCheckpoint,
      );
      expect(await storage.read(key: storageKey), firstRaw);

      await press(tester, 'core-ha-checkpoint-rotate');
      await authorizeCheckpoint(tester, 'core-ha-checkpoint-rotate-confirm');
      final rotated = await storage.read(key: storageKey);
      expect(rotated, contains(harness.integrityCheckpoint));
      expect(rotated, contains('"revision":2'));
      expect(keyed('core-ha-checkpoint-pinned'), findsOneWidget);
      expect(keyed('core-ha-checkpoint-rotate'), findsNothing);
    },
  );

  testWidgets('automatic mismatch raises an alarm and keeps the trusted pin', (
    tester,
  ) async {
    final harness = HaUiHarness();
    await openBindingActivity(tester, harness);
    await press(tester, 'core-ha-checkpoint-pin');
    await authorizeCheckpoint(tester, 'core-ha-checkpoint-pin-confirm');
    final storage = const FlutterSecureStorage();
    final storageKey = CoreHaCheckpointStore.storageKey(
      harness.account.session!.context!,
    );
    final trusted = await storage.read(key: storageKey);

    harness.rejectComparedCheckpoint = true;
    await scrollToTop(tester);
    await press(tester, 'core-ha-activity-refresh');
    expect(keyed('core-ha-checkpoint-alarm'), findsOneWidget);
    expect(
      find.text(
        'The trusted checkpoint does not match. Possible rollback or tampering; the saved pin was not changed.',
      ),
      findsOneWidget,
    );
    expect(await storage.read(key: storageKey), trusted);
    expect(keyed('core-ha-checkpoint-rotate'), findsNothing);
  });

  testWidgets('backgrounding retires a held checkpoint authorization', (
    tester,
  ) async {
    final harness = HaUiHarness();
    await openBindingActivity(tester, harness);
    await press(tester, 'core-ha-checkpoint-pin');
    await reveal(tester, keyed('core-ha-checkpoint-reauth-pin'));
    await tester.enterText(keyed('core-ha-checkpoint-reauth-pin'), '1234');
    final held = tester
        .widget<CupertinoButton>(
          find.descendant(
            of: keyed('core-ha-checkpoint-pin-confirm'),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await flush(tester);
    held();
    await flush(tester);

    final key = CoreHaCheckpointStore.storageKey(
      harness.account.session!.context!,
    );
    expect(await const FlutterSecureStorage().read(key: key), isNull);
    expect(keyed('core-ha-checkpoint-authorization'), findsNothing);
  });

  testWidgets(
    'bounded pagination retains entries and marks failed refresh stale',
    (tester) async {
      final harness = HaUiHarness()
        ..role = 'member'
        ..pagedHistory = true;
      await openSnapshotActivity(tester, harness);
      expect(keyed('core-ha-activity-entry-${'9' * 32}'), findsOneWidget);
      expect(keyed('core-ha-activity-entry-${'8' * 32}'), findsNothing);
      await press(tester, 'core-ha-activity-more');
      expect(keyed('core-ha-activity-entry-${'8' * 32}'), findsOneWidget);
      expect(harness.historyReads, 2);
      harness.historyStatus = 503;
      await press(tester, 'core-ha-activity-refresh');
      expect(keyed('core-ha-activity-entry-${'9' * 32}'), findsOneWidget);
      expect(keyed('core-ha-activity-entry-${'8' * 32}'), findsOneWidget);
      expect(
        find.text('Showing retained activity because Core is offline.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('backgrounded pending history cannot publish late success', (
    tester,
  ) async {
    final harness = HaUiHarness()
      ..role = 'member'
      ..pendingHistory = Completer();
    await openSnapshotActivity(tester, harness);
    expect(keyed('core-ha-activity-loading'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await flush(tester);
    harness.pendingHistory!.complete(
      harness.json(harness.history['complete']['response']),
    );
    await flush(tester);
    expect(keyed('core-ha-activity-entry-${'9' * 32}'), findsNothing);
    expect(harness.haReads, 0);
  });

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('$locale $width 2x activity remains keyboard accessible', (
        tester,
      ) async {
        final harness = HaUiHarness()..role = 'member';
        await openSnapshotActivity(
          tester,
          harness,
          locale: locale,
          width: width,
          scale: 2,
        );
        final button = find.descendant(
          of: keyed('core-ha-activity-refresh'),
          matching: find.byType(CupertinoButton),
        );
        await reveal(tester, button);
        final rect = tester.getRect(button);
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        FocusManager.instance.primaryFocus?.unfocus();
        var reached = false;
        for (var index = 0; index < 24; index++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final context = FocusManager.instance.primaryFocus?.context;
          if (context != null &&
              context.findAncestorWidgetOfExactType<CupertinoButton>() ==
                  tester.widget<CupertinoButton>(button)) {
            reached = true;
            break;
          }
        }
        expect(reached, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await flush(tester);
        expect(harness.historyReads, 2);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
