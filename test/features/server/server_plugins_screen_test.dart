import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/server/plugins/presentation/server_plugins_screen.dart';
import 'package:larenor/features/server/services/presentation/server_services_screen.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_plugins_test_support.dart';

void main() {
  late PluginsFixture fixture;
  final navigator = GlobalKey<NavigatorState>();

  Future<void> mount(
    WidgetTester tester, {
    AppInteractionController? interaction,
    ValueNotifier<bool>? visible,
    bool gate = false,
    ServerRole role = ServerRole.admin,
    double width = 1280,
    double scale = 1,
    String language = 'en',
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    fixture = PluginsFixture(role: role);
    await fixture.account.initialize();
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
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
          home: gate
              ? const SettingsGateScreen()
              : visible == null
              ? const ServerPluginsScreen()
              : ValueListenableBuilder(
                  valueListenable: visible,
                  builder: (_, enabled, _) => TickerMode(
                    enabled: enabled,
                    child: const ServerPluginsScreen(),
                  ),
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
    });
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> field(WidgetTester tester, String key, String text) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.enterText(finder, text);
    await tester.pump();
  }

  testWidgets(
    'six real components are unavailable and music has no standalone action',
    (tester) async {
      await mount(tester);
      expect(fixture.mutations, isEmpty);
      for (final name in [
        'Jellyfin',
        'Seerr',
        'Sonarr',
        'Radarr',
        'qBittorrent',
        'Music Assistant',
      ]) {
        await tester.scrollUntilVisible(find.text(name), 400);
        expect(find.text(name), findsOneWidget);
      }
      expect(
        find.byKey(const ValueKey('plugin-review-music_assistant')),
        findsNothing,
      );
      expect(
        find.text('Larenor Server internal music component · in development'),
        findsOneWidget,
      );
      expect(find.byType(CupertinoTextField), findsNothing);
      expect(fixture.mutations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit platform and settings create only a requirements preview',
    (tester) async {
      await mount(tester);
      await tap(tester, 'plugin-review-jellyfin');
      await tap(tester, 'plugin-preview-submit');
      expect(fixture.mutations, isEmpty);
      await tap(tester, 'plugin-platform-linux/amd64');
      await field(tester, 'plugin-setting-dataRootId', '/etc');
      await tap(tester, 'plugin-preview-submit');
      expect(fixture.mutations, isEmpty);
      await field(tester, 'plugin-setting-dataRootId', 'appdata');
      final action = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('plugin-preview-submit')),
          )
          .onPressed!;
      action();
      action();
      await tester.pumpAndSettle();
      expect(fixture.mutations, hasLength(1));
      expect(
        find.byKey(const ValueKey('plugin-preview-close')),
        findsOneWidget,
      );
      expect(find.textContaining('does not pull images'), findsOneWidget);
      expect(find.text('Requested effects'), findsOneWidget);
      expect(find.text('TCP 8096 → 8096'), findsOneWidget);
      expect(
        find.textContaining('appdata / jellyfin/config → /config'),
        findsOneWidget,
      );
      expect(find.text('Install'), findsNothing);
      expect(find.text('Confirm installation'), findsNothing);
      await tap(tester, 'plugin-preview-close');
      expect(find.byKey(const ValueKey('plugin-preview-close')), findsNothing);
      expect(fixture.mutations, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'custom settings round trip the real Python plan on tablet with keyboard',
    (tester) async {
      await mount(tester, scale: 2, language: 'tr');
      await tap(tester, 'plugin-review-jellyfin');
      tester.view.viewInsets = const FakeViewPadding(bottom: 350);
      await tester.pumpAndSettle();
      await tap(tester, 'plugin-platform-linux/arm64');
      await field(tester, 'plugin-setting-instanceName', 'living-room');
      await field(tester, 'plugin-setting-dataRootId', 'disk_a');
      await field(tester, 'plugin-setting-webPort', '18096');
      await field(tester, 'plugin-setting-mediaRootId', 'movies');
      final submit = find.byKey(const ValueKey('plugin-preview-submit'));
      expect(tester.getBottomLeft(submit).dy, lessThanOrEqualTo(650));
      await tap(tester, 'plugin-preview-submit');
      expect(fixture.mutations, hasLength(1));
      expect(jsonDecode(fixture.mutations.single.body)['settings'], {
        'instanceName': 'living-room',
        'dataRootId': 'disk_a',
        'webPort': 18096,
        'mediaRootId': 'movies',
      });
      expect(
        find.byKey(const ValueKey('plugin-preview-close')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'qBittorrent rejects overlapping ports before a preview request',
    (tester) async {
      await mount(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('plugin-review-qbittorrent')),
        400,
      );
      await tap(tester, 'plugin-review-qbittorrent');
      await tap(tester, 'plugin-platform-linux/amd64');
      await field(tester, 'plugin-setting-torrentPort', '8080');
      await tap(tester, 'plugin-preview-submit');
      expect(fixture.mutations, isEmpty);
      expect(
        find.byKey(const ValueKey('plugin-preview-submit')),
        findsOneWidget,
      );
    },
  );

  for (final reason in [
    'background',
    'idle',
    'hidden',
    'account',
    'pin',
    'route',
  ]) {
    testWidgets(
      '$reason clears settings and makes a retained preview action inert',
      (tester) async {
        final interaction = AppInteractionController();
        final visible = ValueNotifier(true);
        addTearDown(interaction.dispose);
        addTearDown(visible.dispose);
        await mount(tester, interaction: interaction, visible: visible);
        await tap(tester, 'plugin-review-jellyfin');
        await tap(tester, 'plugin-platform-linux/amd64');
        final old = tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('plugin-preview-submit')),
            )
            .onPressed!;
        switch (reason) {
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            await tester.pump();
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          case 'idle':
            interaction.setActive(false);
            await tester.pump();
            interaction.setActive(true);
          case 'hidden':
            visible.value = false;
            await tester.pump();
            visible.value = true;
          case 'account':
            await fixture.account.signOut();
          case 'pin':
            final container = ProviderScope.containerOf(
              tester.element(find.byType(ServerPluginsScreen)),
            );
            await container.read(pinLockProvider.notifier).setPin('5678');
          case 'route':
            navigator.currentState!.push(
              PageRouteBuilder<void>(
                opaque: false,
                pageBuilder: (_, _, _) =>
                    const Center(child: Text('Unrelated cover')),
              ),
            );
        }
        await tester.pumpAndSettle();
        old();
        await tester.pumpAndSettle();
        expect(fixture.mutations, isEmpty);
        expect(
          find.byKey(const ValueKey('plugin-preview-submit')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a late preview response after background cannot reopen its dialog',
    (tester) async {
      await mount(tester);
      await tap(tester, 'plugin-review-jellyfin');
      await tap(tester, 'plugin-platform-linux/amd64');
      final response = Completer<http.Response>();
      fixture.respond = (_) => response.future;
      await tester.tap(find.byKey(const ValueKey('plugin-preview-submit')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      response.complete(fixture.json(pluginPreviewJson(), 201));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('plugin-preview-close')), findsNothing);
      expect(fixture.mutations, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background retires token rotation before a preview can dispatch',
    (tester) async {
      await mount(tester);
      await tap(tester, 'plugin-review-jellyfin');
      await tap(tester, 'plugin-platform-linux/amd64');
      fixture.now = fixture.now.add(const Duration(hours: 2));
      fixture.refresh = Completer<http.Response>();
      await tester.tap(find.byKey(const ValueKey('plugin-preview-submit')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      fixture.refresh!.complete(fixture.pair());
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.mutations, isEmpty);
      expect(fixture.account.session, isNull);
    },
  );

  testWidgets(
    'catalog conflict requires explicit refresh without automatic preview retries',
    (tester) async {
      await mount(tester);
      await tap(tester, 'plugin-review-jellyfin');
      await tap(tester, 'plugin-platform-linux/amd64');
      fixture.respond = (_) async => fixture.json({
        'error': {
          'code': 'plugin_catalog_changed',
          'message': 'synthetic-secret',
        },
      }, 409);
      await tap(tester, 'plugin-preview-submit');
      expect(fixture.mutations, hasLength(1));
      expect(find.textContaining('synthetic-secret'), findsNothing);
      expect(
        find.byKey(const ValueKey('plugin-review-jellyfin')),
        findsNothing,
      );
      fixture.respond = (request) async => fixture.pluginResponse(request);
      await tap(tester, 'plugins-refresh');
      expect(
        find.byKey(const ValueKey('plugin-review-jellyfin')),
        findsOneWidget,
      );
      expect(fixture.mutations, hasLength(1));
    },
  );

  testWidgets('expired previews say so and have only a close action', (
    tester,
  ) async {
    await mount(tester);
    await tap(tester, 'plugin-review-jellyfin');
    await tap(tester, 'plugin-platform-linux/amd64');
    fixture.respond = (_) async =>
        fixture.json(pluginPreviewJson(now: DateTime.utc(2020)), 201);
    await tap(tester, 'plugin-preview-submit');
    expect(find.textContaining('preview has expired'), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-preview-close')), findsOneWidget);
    expect(fixture.mutations, hasLength(1));
  });

  testWidgets(
    'settings PIN protects the component entry before any catalog request',
    (tester) async {
      await mount(tester, gate: true);
      expect(find.byType(ServerPluginsScreen), findsNothing);
      expect(fixture.adminCalls, isEmpty);
      await tester.enterText(find.byType(CupertinoTextField), '1234');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Larenor Server'));
      await tester.pumpAndSettle();
      await tap(tester, 'server-plugins');
      expect(find.byType(ServerPluginsScreen), findsOneWidget);
      expect(fixture.adminCalls, hasLength(1));
    },
  );

  testWidgets('members cannot read catalog or preview', (tester) async {
    await mount(tester, role: ServerRole.member);
    expect(find.byKey(const ValueKey('plugins-refresh')), findsNothing);
    expect(fixture.adminCalls, isEmpty);
  });

  testWidgets(
    'existing-service action is optional and opens the guarded connection screen',
    (tester) async {
      await mount(tester);
      await tap(tester, 'plugins-connect');
      expect(find.byType(ServerServicesScreen), findsOneWidget);
      expect(find.byType(ServerPluginsScreen), findsNothing);
      expect(fixture.mutations, isEmpty);
    },
  );
}
