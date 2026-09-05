import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_preparations/presentation/server_media_preparations_screen.dart';
import 'package:larenor/features/server/media_preparations/presentation/server_media_inspections_screen.dart';
import 'package:larenor/features/server/media_preparations/domain/server_media_preparation_models.dart';
import 'package:larenor/features/server/plugins/presentation/server_plugins_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_media_preparations_test_support.dart';
import 'server_media_inspections_test_support.dart';

void main() {
  late MediaInspectionsFixture f;
  final navigator = GlobalKey<NavigatorState>();
  Future<void> mount(
    WidgetTester tester, {
    bool gate = false,
    bool catalog = false,
    bool preparationEntry = false,
    bool review = false,
    bool configured = true,
    String state = 'queued',
    ValueNotifier<bool>? visible,
    AppInteractionController? interaction,
    String language = 'en',
    double scale = 1,
    double width = 1280,
    ServerRole role = ServerRole.admin,
    bool mustChange = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    f = MediaInspectionsFixture(role: role, mustChange: mustChange)
      ..configured = configured;
    f.inspections.add(mediaInspectionJson(state: state));
    await f.account.initialize();
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget page = ServerMediaInspectionsScreen(
      preparation: review
          ? ServerMediaPreparation.fromJson(f.records.single)
          : null,
    );
    if (preparationEntry) page = const ServerMediaPreparationsScreen();
    if (gate) page = const SettingsGateScreen();
    if (catalog) page = const ServerPluginsScreen();
    final target = page;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(f.account),
        ],
        child: CupertinoApp(
          navigatorKey: navigator,
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) {
            Widget view = MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            );
            if (interaction != null) {
              view = AppInteractionScope(controller: interaction, child: view);
            }
            return view;
          },
          home: visible == null
              ? target
              : ValueListenableBuilder(
                  valueListenable: visible,
                  builder: (_, enabled, _) =>
                      TickerMode(enabled: enabled, child: target),
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      f.account.dispose();
    });
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'preparation entry opens durable inspection history without launch',
    (tester) async {
      await mount(tester, preparationEntry: true);
      await tap(tester, 'media-inspections-history');
      expect(find.text('Media inspections'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('inspection-view-00000000000000000000000000000001'),
        ),
        findsOneWidget,
      );
      expect(f.mutations, isEmpty);
    },
  );
  testWidgets(
    'prepared record starts an explicit readonly inspection and no automatic host action',
    (tester) async {
      await mount(tester, preparationEntry: true);
      await tap(tester, 'media-view-${f.records.single['id']}');
      await tap(tester, 'media-inspect');
      expect(f.mutations, isEmpty);
      expect(find.textContaining('does not install'), findsWidgets);
      await tap(tester, 'inspections-launch');
      expect(f.mutations, hasLength(1));
      expect(
        f.mutations.single.url.path,
        '/prefix/api/v1/admin/media/inspections',
      );
      expect(find.text('Queued'), findsOneWidget);
      expect(find.byType(CupertinoTextField), findsNothing);
    },
  );
  testWidgets(
    'unconfigured worker disables launch but history remains visible',
    (tester) async {
      await mount(tester, review: true, configured: false);
      expect(find.textContaining('not configured'), findsOneWidget);
      expect(
        tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('inspections-launch')),
            )
            .onPressed,
        isNull,
      );
      await tap(tester, 'inspection-view-00000000000000000000000000000001');
      expect(find.text('Queued'), findsOneWidget);
      expect(f.mutations, isEmpty);
    },
  );
  for (final language in ['en', 'tr']) {
    testWidgets(
      '$language tablet 2x distinguishes local storage and daemon context from installation',
      (tester) async {
        await mount(tester, state: 'succeeded', language: language, scale: 2);
        await tap(tester, 'inspection-view-00000000000000000000000000000001');
        final l = AppLocalizations.of(
          tester.element(find.byType(ServerMediaInspectionsScreen)),
        );
        expect(find.text(l.serverJobsSucceeded), findsOneWidget);
        for (final row in [
          (l.serverJobsCheckRoot, l.serverJobsPassed),
          (l.serverJobsCheckCapacity, l.serverJobsPassed),
          (l.serverJobsCheckDaemonMount, l.serverJobsUnknown),
          (l.serverJobsCheckDaemonNetwork, l.serverJobsUnknown),
          (l.serverJobsCheckDaemonRoot, l.serverJobsUnknown),
          (l.serverJobsCheckPorts, l.serverJobsUnknown),
          (l.serverJobsCheckNetwork, l.serverJobsUnknown),
        ]) {
          await tester.scrollUntilVisible(find.text(row.$1), 200);
          final parent = find
              .ancestor(of: find.text(row.$1), matching: find.byType(Column))
              .first;
          expect(
            find.descendant(of: parent, matching: find.text(row.$2)),
            findsOneWidget,
          );
        }
        expect(f.mutations, isEmpty);
        expect(find.byKey(const ValueKey('inspections-cancel')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final reason in [
    'background',
    'hidden',
    'account',
    'route',
    'idle',
    'pin',
  ]) {
    testWidgets(
      '$reason retires cancellation, polling and stale confirmation',
      (tester) async {
        final visible = ValueNotifier(true);
        final interaction = AppInteractionController();
        addTearDown(visible.dispose);
        addTearDown(interaction.dispose);
        await mount(tester, visible: visible, interaction: interaction);
        await tap(tester, 'inspection-view-00000000000000000000000000000001');
        await tap(tester, 'inspections-cancel');
        final stale = tester
            .widget<CupertinoDialogAction>(
              find.byKey(const ValueKey('inspections-cancel-confirm')),
            )
            .onPressed!;
        switch (reason) {
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
          case 'hidden':
            visible.value = false;
          case 'account':
            await f.account.signOut();
          case 'route':
            unawaited(
              navigator.currentState!.push(
                CupertinoPageRoute<void>(
                  builder: (_) =>
                      const CupertinoPageScaffold(child: Text('Covered')),
                ),
              ),
            );
          case 'idle':
            interaction.setActive(false);
          case 'pin':
            final container = ProviderScope.containerOf(
              tester.element(find.byType(ServerMediaInspectionsScreen)),
            );
            await container.read(pinLockProvider.notifier).setPin('5678');
        }
        await tester.pumpAndSettle();
        stale();
        await tester.pump(const Duration(seconds: 20));
        expect(
          f.mutations.where((r) => r.url.path.endsWith('/cancel')),
          isEmpty,
        );
        expect(
          find.byKey(const ValueKey('inspections-cancel-confirm')),
          findsNothing,
        );
        if (reason == 'background')
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
      },
    );
  }
  testWidgets(
    'revision confirmation sends one cancel then stops automatic polling',
    (tester) async {
      await mount(tester);
      await tap(tester, 'inspection-view-00000000000000000000000000000001');
      await tap(tester, 'inspections-cancel');
      await tap(tester, 'inspections-cancel-confirm');
      expect(f.inspections.single['state'], 'cancelled');
      final reads = f.calls.length;
      await tester.pump(const Duration(seconds: 20));
      expect(f.calls, hasLength(reads));
      expect(f.mutations, hasLength(1));
    },
  );
  testWidgets('active polling is single-flight and stops on unknown response', (
    tester,
  ) async {
    await mount(tester);
    await tap(tester, 'inspection-view-00000000000000000000000000000001');
    final held = Completer<http.Response>();
    f.respond = (r) => held.future;
    final reads = f.calls.length;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 15));
    expect(f.calls, hasLength(reads + 1));
    held.complete(http.Response('synthetic-secret', 502));
    await tester.pumpAndSettle();
    final after = f.calls.length;
    await tester.pump(const Duration(seconds: 30));
    expect(f.calls, hasLength(after));
  });
  testWidgets(
    'lost POST response only recovers on explicit same-request action',
    (tester) async {
      await mount(tester, review: true);
      f.respond = (r) async {
        final result = f.pluginResponse(r);
        return r.method == 'POST'
            ? http.Response('synthetic-secret', 502)
            : result;
      };
      await tap(tester, 'inspections-launch');
      final first = f.mutations.single.body;
      await tester.pump(const Duration(seconds: 30));
      expect(f.mutations, hasLength(1));
      f.respond = (r) async => f.pluginResponse(r);
      await tap(tester, 'inspections-recover');
      expect(f.mutations.last.body, first);
      expect(find.text('Queued'), findsOneWidget);
    },
  );
  testWidgets(
    'pending POST is retired on hide and its late result cannot reappear',
    (tester) async {
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await mount(tester, review: true, visible: visible);
      final held = Completer<http.Response>();
      f.respond = (r) =>
          r.method == 'POST' ? held.future : Future.value(f.pluginResponse(r));
      await tester.ensureVisible(
        find.byKey(const ValueKey('inspections-launch')),
      );
      await tester.tap(find.byKey(const ValueKey('inspections-launch')));
      await tester.pump();
      final response = f.pluginResponse(f.mutations.single);
      visible.value = false;
      await tester.pump();
      held.complete(response);
      await tester.pumpAndSettle();
      visible.value = true;
      await tester.pumpAndSettle();
      expect(find.text('Queued'), findsNothing);
      expect(find.byKey(const ValueKey('inspections-recover')), findsNothing);
    },
  );
  testWidgets('members cannot read or launch inspections', (tester) async {
    await mount(tester, role: ServerRole.member, review: true);
    expect(
      f.calls.any((r) => r.url.path.contains('/media/inspections')),
      isFalse,
    );
    expect(f.mutations, isEmpty);
  });
}
