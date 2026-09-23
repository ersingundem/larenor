import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/hub/presentation/media_hub_screen.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/features/media/qbittorrent/providers/qbittorrent_providers.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/settings/providers/enabled_services_providers.dart';
import 'package:larenor/features/settings/presentation/panes/integrations_pane.dart';
import 'package:larenor/features/settings/presentation/panes/settings_nav_row.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  AppInteractionController? interaction,
  HomeSessionController? home,
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (home != null) homeSessionControllerProvider.overrideWithValue(home),
      ],
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: interaction == null
            ? const IntegrationsPane()
            : AppInteractionScope(
                controller: interaction,
                child: const IntegrationsPane(),
              ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

class _CoreSource implements HomeSourcePersistence {
  @override
  Future<HomeSource> read() async => HomeSource.verifiedCore;

  @override
  Future<void> write(HomeSource source) async {}
}

class _EmptySessionStore implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? session) async {}
}

Future<(HomeSessionController, ServerAccountController)> _coreHome() async {
  final account = ServerAccountController(store: _EmptySessionStore());
  final home = HomeSessionController(store: _CoreSource(), account: account);
  await home.initialize();
  return (home, account);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language integrations hub action is accessible at ${width}px 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          await _mount(tester, language: language, width: width);

          expect(find.byType(SettingsPaneScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          expect(find.byType(SettingsActionTile), findsWidgets);
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('integrations-settings-header')),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );

          final hub = find.byKey(
            const ValueKey('integrations-media-hub-action'),
          );
          expect(tester.getRect(hub).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(hub).flagsCollection.isButton, isTrue);
          Focus.of(
            tester.element(
              find.descendant(of: hub, matching: find.byType(Text)).first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(find.byType(MediaHubScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }

  testWidgets('idle retires a captured integration navigation callback', (
    tester,
  ) async {
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await _mount(tester, language: 'en', width: 600, interaction: interaction);
    final stale = tester
        .widget<CupertinoButton>(
          find.descendant(
            of: find.byKey(const ValueKey('integrations-media-hub-action')),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;

    interaction.setActive(false);
    interaction.setActive(true);
    await tester.pump();
    stale();
    await tester.pumpAndSettle();

    expect(find.byType(MediaHubScreen), findsNothing);
    expect(find.byType(IntegrationsPane), findsOneWidget);
  });

  testWidgets('Core integrations never construct Direct service providers', (
    tester,
  ) async {
    final (home, account) = await _coreHome();
    addTearDown(() {
      home.dispose();
      account.dispose();
    });
    await _mount(tester, language: 'en', width: 600, home: home, settle: false);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(IntegrationsPane)),
      listen: false,
    );

    expect(home.usesLocalHome, isFalse);
    expect(
      find.byKey(const ValueKey('integrations-media-hub-action')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('integrations-manage-direct-action')),
      findsNothing,
    );
    expect(container.exists(enabledServicesProvider), isFalse);
    expect(container.exists(jellyfinConnectionProvider), isFalse);
    expect(container.exists(jellyseerrConnectionProvider), isFalse);
    expect(container.exists(sonarrConnectionProvider), isFalse);
    expect(container.exists(qbittorrentConnectionProvider), isFalse);
  });
}
