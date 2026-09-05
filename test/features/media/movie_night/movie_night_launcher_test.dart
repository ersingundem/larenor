import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/dashboard/presentation/entity_picker_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/rest_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/ha_tools/domain/ha_action.dart';
import 'package:larenor/features/ha_tools/presentation/ha_actions_screen.dart';
import 'package:larenor/features/health/data/health_monitor.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/health/providers/health_providers.dart';
import 'package:larenor/features/media/movie_night/domain/movie_night_preset.dart';
import 'package:larenor/features/media/movie_night/presentation/movie_night_launcher.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/direct_home_routines_test.dart' show routinesHome;

const _config = HaConnectionConfig(
  baseUrl: 'https://ha.test',
  token: 'fixture',
);
const _preset = MovieNightPreset(
  serverUrl: 'https://ha.test',
  startEntityId: 'scene.cinema',
  finishEntityId: 'scene.finish',
);

class _Entities extends Entities {
  @override
  Future<Map<String, HaEntity>> build() async => const {
    'scene.cinema': HaEntity(
      entityId: 'scene.cinema',
      state: 'unknown',
      attributes: {'friendly_name': 'Sinema ışığı'},
    ),
    'scene.finish': HaEntity(
      entityId: 'scene.finish',
      state: 'unknown',
      attributes: {'friendly_name': 'Gece ışığı'},
    ),
  };
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    List<String> operations, {
    bool fresh = true,
    bool narrow = false,
    AppInteractionController? interaction,
    HomeSessionController? home,
  }) async {
    final scope = interaction ?? AppInteractionController();
    if (interaction == null) addTearDown(scope.dispose);
    SharedPreferences.setMockInitialValues({
      MovieNightPreset.storageKey: _preset.encodeStored(),
    });
    final rest = HaRestClient(
      baseUrl: _config.baseUrl,
      token: _config.token,
      httpClient: MockClient((request) async {
        operations.add(request.body);
        return http.Response('[]', 200);
      }),
    );
    addTearDown(rest.dispose);
    final health = HealthMonitor();
    addTearDown(health.dispose);
    final session = health.bind(
      IntegrationId.ha,
      configured: true,
      configurationIdentity: _config,
    );
    if (fresh) session.readSucceeded();
    if (narrow) {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (home != null) homeSessionControllerProvider.overrideWithValue(home),
          connectionConfigProvider.overrideWithBuild(
            (ref, notifier) async => _config,
          ),
          entitiesProvider.overrideWith(_Entities.new),
          haActionsProvider.overrideWith(
            (ref) async => const [
              HaAction(domain: 'scene', service: 'turn_on', metadata: {}),
            ],
          ),
          haRestClientProvider.overrideWithValue(rest),
          haWebSocketClientProvider.overrideWithValue(null),
          healthMonitorProvider.overrideWithValue(health),
        ],
        child: CupertinoApp(
          locale: const Locale('tr'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(narrow ? 2 : 1)),
            child: AppInteractionScope(controller: scope, child: child!),
          ),
          home: CupertinoPageScaffold(
            child: SafeArea(
              child: MovieNightLauncher(
                title: 'Örnek film',
                isPlaybackCurrent: () => true,
                onPlay: () async {
                  operations.add('player');
                  return true;
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('Film gecesi'));
    // The launcher remains busy behind this route, so no pumpAndSettle here.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('idle removes the owned scene picker above its setup page', (
    tester,
  ) async {
    final scope = AppInteractionController();
    addTearDown(scope.dispose);
    final operations = <String>[];
    await mount(tester, operations, interaction: scope);
    await open(tester);
    await tester.tap(find.text('Başlangıç sahnesi veya betiği'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(EntityPickerScreen), findsOneWidget);
    scope.setActive(false);
    await tester.pump();
    scope.setActive(true);
    await tester.pumpAndSettle();
    expect(find.byType(EntityPickerScreen), findsNothing);
    expect(find.text('Sahneyi uygula ve oynatıcıyı aç'), findsNothing);
    expect(operations, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'idle closes owned setup and an old Start cannot dispatch after wake',
    (tester) async {
      final scope = AppInteractionController();
      addTearDown(scope.dispose);
      final operations = <String>[];
      await mount(tester, operations, interaction: scope);
      await open(tester);
      final start = tester
          .widget<CupertinoButton>(
            find.widgetWithText(
              CupertinoButton,
              'Sahneyi uygula ve oynatıcıyı aç',
            ),
          )
          .onPressed!;
      scope.setActive(false);
      await tester.pump();
      scope.setActive(true);
      await tester.pumpAndSettle();
      start();
      await tester.pumpAndSettle();
      expect(operations, isEmpty);
      expect(find.text('Sahneyi uygula ve oynatıcıyı aç'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'idle closes only finish confirmation and never applies its old scene',
    (tester) async {
      final scope = AppInteractionController();
      addTearDown(scope.dispose);
      final operations = <String>[];
      await mount(tester, operations, interaction: scope);
      await open(tester);
      await tester.tap(find.text('Sahneyi uygula ve oynatıcıyı aç'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final finish = tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Sahneyi uygula'),
          )
          .onPressed!;
      expect(operations.length, 2);
      scope.setActive(false);
      await tester.pump();
      scope.setActive(true);
      await tester.pumpAndSettle();
      finish();
      await tester.pumpAndSettle();
      expect(operations.length, 2);
      expect(find.text('Bitiş sahnesi uygulansın mı?'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'preview sends nothing and cancellation keeps the scene unchanged',
    (tester) async {
      final operations = <String>[];
      await mount(tester, operations);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MovieNightLauncher)),
      );
      expect(container.exists(entitiesProvider), isFalse);
      expect(container.exists(haActionsProvider), isFalse);
      await open(tester);
      expect(find.text('Sinema ışığı'), findsOneWidget);
      expect(operations, isEmpty);
      Navigator.of(tester.element(find.text('Sahneyi uygula ve oynatıcıyı aç')))
          .pop();
      await tester.pumpAndSettle();
      expect(operations, isEmpty);
    },
  );

  testWidgets(
    'explicit start sends scene then opens player; finish cancellation sends nothing else',
    (tester) async {
      final operations = <String>[];
      await mount(tester, operations);
      await open(tester);
      await tester.tap(find.text('Sahneyi uygula ve oynatıcıyı aç'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(operations, ['{"entity_id":"scene.cinema"}', 'player']);
      expect(find.text('Bitiş sahnesi uygulansın mı?'), findsOneWidget);
      await tester.tap(find.text('İptal'));
      await tester.pumpAndSettle();
      expect(operations.length, 2);
    },
  );

  testWidgets('stale connection never dispatches the scene or opens player', (
    tester,
  ) async {
    final operations = <String>[];
    await mount(tester, operations, fresh: false);
    await open(tester);
    await tester.tap(find.text('Sahneyi uygula ve oynatıcıyı aç'));
    await tester.pumpAndSettle();
    expect(operations, isEmpty);
    expect(find.textContaining('Sahne sonucu doğrulanamadı'), findsOneWidget);
  });

  testWidgets('preview stays scrollable on 320px at 2x Turkish text', (
    tester,
  ) async {
    final operations = <String>[];
    await mount(tester, operations, narrow: true);
    await open(tester);
    await tester.scrollUntilVisible(
      find.text('Sahneyi uygula ve oynatıcıyı aç'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    expect(operations, isEmpty);
    Navigator.of(tester.element(find.text('Sahneyi uygula ve oynatıcıyı aç')))
        .pop();
    await tester.pumpAndSettle();
  });
  testWidgets('old movie launch cannot open setup after Direct source round trip', (tester) async {
    final (_, home) = await routinesHome('direct');
    final operations = <String>[];
    await mount(tester, operations, home: home);
    final launch = tester.widget<CupertinoButton>(find.widgetWithText(CupertinoButton,'Film gecesi')).onPressed!;
    await home.choose(HomeSource.verifiedCore);
    await home.choose(HomeSource.directLocal);
    launch();
    await tester.pump(); await tester.pump(const Duration(milliseconds:400));
    expect(find.text('Sahneyi uygula ve oynatıcıyı aç'), findsNothing);
    expect(operations, isEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('source switch cancels old movie Start even with unchanged HA account', (tester) async {
    final (_, home) = await routinesHome('direct');
    final operations = <String>[];
    await mount(tester, operations, home: home);
    await open(tester);
    final start = tester.widget<CupertinoButton>(find.widgetWithText(CupertinoButton,'Sahneyi uygula ve oynatıcıyı aç')).onPressed!;
    await home.choose(HomeSource.verifiedCore);
    start();
    await tester.pump(); await tester.pump(const Duration(milliseconds:400));
    expect(operations, isEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

}
