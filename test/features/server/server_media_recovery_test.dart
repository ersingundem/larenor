import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/server/media_preparations/presentation/server_media_preparations_screen.dart';
import 'package:larenor/features/server/media_recovery/data/server_media_recovery_controller.dart';
import 'package:larenor/features/server/media_recovery/domain/server_media_recovery_models.dart';
import 'package:larenor/features/server/media_recovery/presentation/server_media_recovery_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:intl/intl.dart';

import 'server_admin_test_support.dart';

Map<String, dynamic> recoveryJson() => {
  'schemaVersion': 2,
  'state': 'incomplete',
  'installAvailable': false,
  'services': [
    for (var index = 0; index < mediaRecoveryServiceOrder.length; index++)
      if (index == 0)
        {
          'serviceId': 'larenor_core',
          'sourceId': 'a' * 32,
          'sourceKind': 'core',
          'revision': 1,
          'resultState': 'verified',
          'containerState': 'started',
          'serviceState': 'verified',
          'storedState': 'stored',
          'reachableState': 'reachable',
          'verifiedState': 'verified',
          'recoveryAction': 'none',
          'automaticRetry': false,
          'errorCode': null,
          'updatedAt': null,
        }
      else
        {
          'serviceId': mediaRecoveryServiceOrder[index],
          'sourceId': null,
          'sourceKind': 'missing',
          'revision': null,
          'resultState': 'missing',
          'containerState': 'unknown',
          'serviceState': 'unverified',
          'storedState': 'missing',
          'reachableState': 'unknown',
          'verifiedState': 'unverified',
          'recoveryAction': 'configure',
          'automaticRetry': false,
          'errorCode': null,
          'updatedAt': null,
        },
  ],
};

class RecoveryFixture extends AdminFixture {
  RecoveryFixture() {
    respond = (request) async {
      if (request.url.path.endsWith('/admin/media/recovery-status')) {
        return pending?.future ?? json(recoveryJson());
      }
      return defaultResponse(request);
    };
  }
  Completer<http.Response>? pending;
}

void main() {
  test('contract rejects hidden connection fields and service reordering', () {
    expect(
      ServerMediaRecoveryStatus.fromJson(recoveryJson()).services,
      hasLength(7),
    );
    final secret = recoveryJson();
    (secret['services'] as List).first['token'] = 'must-not-cross-boundary';
    expect(
      () => ServerMediaRecoveryStatus.fromJson(secret),
      throwsA(anyOf(isA<LarenorServerException>(), isA<FormatException>())),
    );
    final reordered = recoveryJson();
    final services = reordered['services'] as List;
    final first = services.removeAt(0);
    services.add(first);
    expect(
      () => ServerMediaRecoveryStatus.fromJson(reordered),
      throwsA(anyOf(isA<LarenorServerException>(), isA<FormatException>())),
    );
    final missingCore = recoveryJson();
    final core = (missingCore['services'] as List).first;
    core
      ..['sourceId'] = null
      ..['sourceKind'] = 'missing'
      ..['revision'] = null
      ..['resultState'] = 'missing'
      ..['containerState'] = 'unknown'
      ..['serviceState'] = 'unverified'
      ..['storedState'] = 'missing'
      ..['reachableState'] = 'unknown'
      ..['verifiedState'] = 'unverified'
      ..['recoveryAction'] = 'configure';
    expect(
      () => ServerMediaRecoveryStatus.fromJson(missingCore),
      throwsA(anyOf(isA<LarenorServerException>(), isA<FormatException>())),
    );
    final contradictory = recoveryJson();
    final service = (contradictory['services'] as List)[1];
    service
      ..['sourceId'] = 'b' * 32
      ..['sourceKind'] = 'configuration'
      ..['revision'] = 1
      ..['resultState'] = 'failed'
      ..['containerState'] = 'started'
      ..['storedState'] = 'stored'
      ..['recoveryAction'] = 'retry';
    expect(
      () => ServerMediaRecoveryStatus.fromJson(contradictory),
      throwsA(anyOf(isA<LarenorServerException>(), isA<FormatException>())),
      reason: 'failed evidence requires a bounded public error code',
    );
    final undatedEvidence = recoveryJson();
    (undatedEvidence['services'] as List).first['updatedAt'] =
        'not-a-utc-observation';
    expect(
      () => ServerMediaRecoveryStatus.fromJson(undatedEvidence),
      throwsA(isA<FormatException>()),
      reason: 'the dated historical receipt must have a valid UTC time',
    );
  });

  test('account change discards an in-flight installation snapshot', () async {
    final fixture = RecoveryFixture();
    fixture.pending = Completer<http.Response>();
    await fixture.account.initialize();
    final controller = ServerMediaRecoveryController(fixture.account);
    addTearDown(controller.dispose);
    addTearDown(fixture.account.dispose);
    final future = controller.load(current: () => true);
    await Future<void>.delayed(Duration.zero);
    await fixture.account.signOut();
    fixture.pending!.complete(fixture.json(recoveryJson()));
    await future;
    expect(controller.status, isNull);
    expect(controller.busy, isFalse);
  });

  test(
    'route authority callback failures stay closed without busy lockout',
    () async {
      final fixture = RecoveryFixture();
      await fixture.account.initialize();
      final controller = ServerMediaRecoveryController(fixture.account);
      addTearDown(controller.dispose);
      addTearDown(fixture.account.dispose);

      await expectLater(
        controller.load(current: () => throw StateError('route unavailable')),
        completes,
      );
      expect(
        fixture.calls.where(
          (request) =>
              request.url.path.endsWith('/admin/media/recovery-status'),
        ),
        isEmpty,
      );
      expect(controller.busy, isFalse);

      fixture.pending = Completer<http.Response>();
      var current = true;
      final pending = controller.load(
        current: () =>
            current ? true : throw StateError('route retired during response'),
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      fixture.pending!.complete(fixture.json(recoveryJson()));

      await expectLater(pending, completes);
      expect(controller.status, isNull);
      expect(controller.busy, isFalse);
    },
  );

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('status is accessible at $locale $width and 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final fixture = RecoveryFixture();
        FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
        await fixture.account.initialize();
        addTearDown(fixture.account.dispose);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1100);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              serverAccountControllerProvider.overrideWithValue(
                fixture.account,
              ),
            ],
            child: CupertinoApp(
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const ServerMediaRecoveryScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final key in const [
          'server-recovery-refresh',
          'server-recovery-operator',
          'server-recovery-providers',
        ]) {
          final action = find.byKey(ValueKey(key));
          expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(action).flagsCollection.isButton, isTrue);
        }
        final refresh = find.byKey(const ValueKey('server-recovery-refresh'));
        await tester.ensureVisible(refresh);
        await tester.tap(refresh);
        await tester.pumpAndSettle();
        expect(
          fixture.calls
              .where(
                (call) =>
                    call.url.path.endsWith('/admin/media/recovery-status'),
              )
              .length,
          2,
        );
        final heading = find.byKey(
          const ValueKey('server-recovery-status-heading'),
        );
        await tester.scrollUntilVisible(heading, 300);
        expect(heading, findsOneWidget);
        for (final id in mediaRecoveryServiceOrder) {
          final finder = find.byKey(ValueKey('server-recovery-$id'));
          await tester.scrollUntilVisible(finder, 220);
          expect(finder, findsOneWidget);
          expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(finder).label, isNotEmpty);
        }
        semantics.dispose();
      });
    }
  }

  for (final locale in ['en', 'tr']) {
    testWidgets(
      'historical reachability is dated and never presented as live in $locale',
      (tester) async {
        final fixture = RecoveryFixture();
        final snapshot = recoveryJson();
        final qbittorrent = (snapshot['services'] as List).firstWhere(
          (entry) => entry['serviceId'] == 'qbittorrent',
        ) as Map<String, dynamic>;
        qbittorrent.addAll({
          'sourceId': 'b' * 32,
          'sourceKind': 'configuration',
          'revision': 2,
          'resultState': 'verified',
          'containerState': 'started',
          'serviceState': 'verified',
          'storedState': 'stored',
          'reachableState': 'reachable',
          'verifiedState': 'verified',
          'recoveryAction': 'none',
          'updatedAt': '2026-09-20T12:00:00.000Z',
        });
        fixture.respond = (request) async =>
            request.url.path.endsWith('/admin/media/recovery-status')
            ? fixture.json(snapshot)
            : fixture.defaultResponse(request);
        FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
        await fixture.account.initialize();
        addTearDown(fixture.account.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              serverAccountControllerProvider.overrideWithValue(
                fixture.account,
              ),
            ],
            child: CupertinoApp(
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const ServerMediaRecoveryScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final finder = find.byKey(
          const ValueKey('server-recovery-qbittorrent'),
        );
        await tester.scrollUntilVisible(finder, 220);
        final semantics = tester.getSemantics(finder).label;
        expect(
          semantics,
          contains(
            locale == 'tr'
                ? 'Son gözlemde erişilebilir'
                : 'Last observed reachable',
          ),
        );
        final observed = DateFormat.yMd(locale)
            .add_Hm()
            .format(DateTime.parse('2026-09-20T12:00:00.000Z').toLocal());
        expect(semantics, contains(observed));
        expect(
          find.textContaining(
            locale == 'tr'
                ? 'Canlı bağlantı testi değildir'
                : 'This is not a live connection test',
          ),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('operator action is keyboard reachable and opens settings', (
    tester,
  ) async {
    final fixture = RecoveryFixture();
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMediaRecoveryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('server-recovery-operator')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(ServerMediaPreparationsScreen), findsOneWidget);
    expect(
      fixture.mutations,
      isEmpty,
      reason: 'navigation cannot copy or mutate service credentials',
    );

    // Physical keyboard activation is supplied by CupertinoButton.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  });

  testWidgets('captured refresh cannot read after route loses authority', (
    tester,
  ) async {
    final fixture = RecoveryFixture();
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMediaRecoveryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final refresh = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('server-recovery-refresh')),
        )
        .onPressed!;
    int recoveryReads() => fixture.calls
        .where(
          (request) =>
              request.url.path.endsWith('/admin/media/recovery-status'),
        )
        .length;
    expect(recoveryReads(), 1);

    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          CupertinoPageRoute<void>(builder: (_) => const SizedBox.expand()),
        );
    await tester.pumpAndSettle();
    refresh();
    await tester.pump();

    expect(recoveryReads(), 1);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('server-recovery-refresh')),
      findsOneWidget,
      reason: 'returning to the exact route must restore a fresh read surface',
    );
    expect(
      recoveryReads(),
      2,
      reason: 'route resume must reload instead of retaining expired evidence',
    );
  });

  testWidgets('background response is discarded and resume reads fresh state', (
    tester,
  ) async {
    final fixture = RecoveryFixture();
    fixture.pending = Completer<http.Response>();
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMediaRecoveryScreen(),
        ),
      ),
    );
    await tester.pump();
    int recoveryReads() => fixture.calls
        .where(
          (request) =>
              request.url.path.endsWith('/admin/media/recovery-status'),
        )
        .length;
    expect(recoveryReads(), 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    fixture.pending!.complete(fixture.json(recoveryJson()));
    await tester.pump();
    fixture.pending = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(recoveryReads(), 2);
    expect(
      find.byKey(const ValueKey('server-recovery-status-heading')),
      findsOneWidget,
    );
  });
}
