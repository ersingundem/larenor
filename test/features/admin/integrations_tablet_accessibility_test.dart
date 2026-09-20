import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/admin/data/models/config_entry.dart';
import 'package:larenor/features/admin/presentation/integrations_screen.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import 'admin_test_fakes.dart';

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [configEntriesProvider.overrideWith(() => _Entries())],
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const IntegrationsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Entries extends ConfigEntries {
  @override
  Future<List<ConfigEntry>> build() async => const [
    ConfigEntry(
      entryId: 'hue-entry',
      domain: 'hue',
      title: 'Living room lights',
      source: 'user',
      state: 'loaded',
    ),
  ];
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language integration action is accessible at ${width}px 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          await _mount(tester, language: language, width: width);

          expect(find.byType(ServiceRootScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsNWidgets(3));
          expect(find.byType(SettingsActionTile), findsNWidgets(2));
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('ha-integrations-list-header')),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );

          final entry = find.byKey(const ValueKey('ha-integration-hue-entry'));
          await tester.ensureVisible(entry);
          expect(tester.getRect(entry).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(entry).flagsCollection.isButton, isTrue);
          Focus.of(
            tester.element(
              find.descendant(of: entry, matching: find.byType(Text)).first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(find.byType(CupertinoActionSheet), findsOneWidget);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }

  testWidgets(
    'account replacement rejects a destructive action from the old sheet',
    (tester) async {
      final interaction = AppInteractionController();
      final oldSocket = RecordingAdminSocket();
      final newSocket = RecordingAdminSocket();
      final container = ProviderContainer(
        overrides: [
          configEntriesProvider.overrideWith(() => _Entries()),
          haAdminClientProvider.overrideWithValue(fakeAdminClient(oldSocket)),
        ],
      );
      addTearDown(interaction.dispose);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: AppInteractionScope(
            controller: interaction,
            child: CupertinoApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const IntegrationsScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('ha-integration-hue-entry')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(CupertinoActionSheet)),
      );
      final disable = tester
          .widget<CupertinoActionSheetAction>(
            find.widgetWithText(CupertinoActionSheetAction, l10n.commonDisable),
          )
          .onPressed;
      container.updateOverrides([
        configEntriesProvider.overrideWith(() => _Entries()),
        haAdminClientProvider.overrideWithValue(fakeAdminClient(newSocket)),
      ]);
      await tester.pump();
      disable();
      await tester.pumpAndSettle();
      expect(oldSocket.commands, isEmpty);
      expect(newSocket.commands, isEmpty);

      tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('ha-integration-hue-entry')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      tester
          .widget<CupertinoActionSheetAction>(
            find.widgetWithText(CupertinoActionSheetAction, l10n.commonDisable),
          )
          .onPressed();
      await tester.pumpAndSettle();
      expect(oldSocket.commands, isEmpty);
      expect(newSocket.commands, [
        {
          'type': 'config_entries/disable',
          'entry_id': 'hue-entry',
          'disabled_by': 'user',
        },
      ]);
    },
  );

  testWidgets(
    'HA status keeps saved reachable and verified evidence distinct',
    (tester) async {
      final now = DateTime.utc(2026, 9, 20, 18);
      final monitor = HealthMonitor(now: () => now);
      final session = monitor.bind(
        IntegrationId.ha,
        configured: true,
        configurationIdentity: 'fixture-account',
      );
      final container = ProviderContainer(
        overrides: [
          healthMonitorProvider.overrideWithValue(monitor),
          healthClockProvider.overrideWith((ref) => Stream.value(now)),
          configEntriesProvider.overrideWith(() => _Entries()),
          haAdminClientProvider.overrideWithValue(
            fakeAdminClient(RecordingAdminSocket()),
          ),
        ],
      );
      addTearDown(session.close);
      addTearDown(monitor.dispose);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: IntegrationsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final evidence = find.byKey(const ValueKey('connection-evidence-status'));
      final l10n = AppLocalizations.of(tester.element(evidence));
      expect(
        tester.getSemantics(evidence).label,
        contains(l10n.navigationSavedConnection),
      );
      expect(
        tester.getSemantics(evidence).label,
        contains(l10n.healthNotVerified),
      );

      session.contact();
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(evidence).label,
        contains(l10n.healthReachable),
      );
      session.readSucceeded();
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(evidence).label,
        contains(l10n.healthReadCurrent),
      );
    },
  );

  testWidgets('current rename and confirmed delete dispatch exact entry', (
    tester,
  ) async {
    final socket = RecordingAdminSocket();
    final requests = <http.Request>[];
    final container = ProviderContainer(
      overrides: [
        configEntriesProvider.overrideWith(() => _Entries()),
        haAdminClientProvider.overrideWithValue(
          fakeAdminClient(
            socket,
            respond: (request) async {
              requests.add(request);
              return http.Response('{"require_restart":false}', 200);
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const IntegrationsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(IntegrationsScreen)),
    );
    void openActions() => tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('ha-integration-hue-entry')),
        )
        .onPressed!();

    openActions();
    await tester.pumpAndSettle();
    tester
        .widget<CupertinoActionSheetAction>(
          find.widgetWithText(CupertinoActionSheetAction, l10n.commonEdit),
        )
        .onPressed();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField), 'Renamed lights');
    tester
        .widget<CupertinoDialogAction>(
          find.widgetWithText(CupertinoDialogAction, l10n.commonSave),
        )
        .onPressed!();
    await tester.pumpAndSettle();
    expect(socket.commands, [
      {
        'type': 'config_entries/update',
        'entry_id': 'hue-entry',
        'title': 'Renamed lights',
      },
    ]);

    openActions();
    await tester.pumpAndSettle();
    tester
        .widget<CupertinoActionSheetAction>(
          find.widgetWithText(CupertinoActionSheetAction, l10n.commonDelete),
        )
        .onPressed();
    await tester.pumpAndSettle();
    tester
        .widget<CupertinoDialogAction>(
          find.widgetWithText(CupertinoDialogAction, l10n.commonDelete),
        )
        .onPressed!();
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(requests.single.method, 'DELETE');
    expect(
      requests.single.url.path,
      '/api/config/config_entries/entry/hue-entry',
    );
  });
}
