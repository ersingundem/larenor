import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/presentation/home_dashboard_screen.dart';
import 'package:larenor/features/dashboard/presentation/tiles/home_accessory_tile.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/data/ws_client.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/settings/providers/enabled_services_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const fixtureLayout = DashboardLayout(
  favoriteEntityIds: [
    'light.lounge',
    'climate.lounge',
    'lock.front',
    'scene.evening',
  ],
  rooms: [
    DashboardRoom(
      id: 'lounge',
      name: 'Salon',
      entityIds: [
        'light.lounge',
        'climate.lounge',
        'scene.evening',
        'media_player.tv',
      ],
    ),
    DashboardRoom(
      id: 'kitchen',
      name: 'Mutfak',
      entityIds: ['light.kitchen', 'sensor.kitchen', 'switch.coffee'],
    ),
    DashboardRoom(
      id: 'hall',
      name: 'Giriş',
      entityIds: ['lock.front', 'light.removed'],
    ),
  ],
);
final fixtureEntities = <String, HaEntity>{
  for (final entity in const [
    HaEntity(
      entityId: 'light.lounge',
      state: 'on',
      attributes: {'friendly_name': 'Lambader'},
    ),
    HaEntity(
      entityId: 'climate.lounge',
      state: 'heat',
      attributes: {'friendly_name': 'İklim', 'temperature': 22},
    ),
    HaEntity(
      entityId: 'scene.evening',
      state: 'scening',
      attributes: {'friendly_name': 'Film zamanı'},
    ),
    HaEntity(
      entityId: 'media_player.tv',
      state: 'playing',
      attributes: {'friendly_name': 'Salon TV'},
    ),
    HaEntity(
      entityId: 'light.kitchen',
      state: 'off',
      attributes: {'friendly_name': 'Tezgâh ışığı'},
    ),
    HaEntity(
      entityId: 'sensor.kitchen',
      state: '21.5',
      attributes: {
        'friendly_name': 'Sıcaklık',
        'device_class': 'temperature',
        'unit_of_measurement': '°C',
      },
    ),
    HaEntity(
      entityId: 'switch.coffee',
      state: 'off',
      attributes: {'friendly_name': 'Kahve makinesi'},
    ),
    HaEntity(
      entityId: 'lock.front',
      state: 'locked',
      attributes: {'friendly_name': 'Ön kapı'},
    ),
  ])
    entity.entityId: entity,
};

Widget app({
  DashboardLayout layout = fixtureLayout,
  double scale = 1,
  Brightness brightness = Brightness.light,
  GlobalKey? boundary,
}) => ProviderScope(
  overrides: [
    dashboardLayoutProvider.overrideWithBuild((ref, notifier) async => layout),
    entitiesProvider.overrideWithBuild(
      (ref, notifier) async => fixtureEntities,
    ),
    enabledServicesProvider.overrideWithBuild((ref, notifier) async => {}),
    haConnectionStatusProvider.overrideWith(
      (ref) => Stream.value(HaConnectionStatus.connected),
    ),
  ],
  child: CupertinoApp(
    theme: larenorTheme(brightness: brightness),
    locale: const Locale('tr'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: RepaintBoundary(key: boundary, child: const HomeDashboardScreen()),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (name, menuLabel, initial) in [
    ('room', 'Oda ekle', ''),
    ('website', 'Web sitesi ekle', 'https://'),
  ]) {
    testWidgets('$name dialog disposes its editor after the route transition', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(CupertinoIcons.add_circled).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(menuLabel).last);
      await tester.pumpAndSettle();
      final controller = tester
          .widget<CupertinoTextField>(find.byType(CupertinoTextField))
          .controller!;
      expect(controller.text, initial);
      await tester.enterText(find.byType(CupertinoTextField), 'fixture');
      await tester.tap(find.text('İptal').last);
      await tester.pump(const Duration(milliseconds: 10));
      void listener() {}
      expect(
        () => controller.addListener(listener),
        returnsNormally,
        reason: 'The editor is still mounted during the closing animation',
      );
      controller.removeListener(listener);
      await tester.pumpAndSettle();
      expect(() => controller.addListener(listener), throwsFlutterError);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'room selection and category filtering show only matching accessories',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 1024);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mutfak').first);
      await tester.pumpAndSettle();
      expect(find.text('Lambader'), findsNothing);
      expect(find.text('Tezgâh ışığı'), findsOneWidget);
      await tester.tap(find.text('Güvenlik').first);
      await tester.pumpAndSettle();
      expect(find.byType(HomeAccessoryTile), findsNothing);
      expect(find.text('Bu kategoride aksesuar yok'), findsOneWidget);
      expect(find.text('Cihaz ekle'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('favorites survive migration even with no rooms', (tester) async {
    await tester.pumpWidget(
      app(layout: const DashboardLayout(favoriteEntityIds: ['light.lounge'])),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lambader'), findsOneWidget);
    expect(find.text('Henüz oda yok'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing saved entities remain removable unavailable tiles', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        layout: const DashboardLayout(
          rooms: [
            DashboardRoom(
              id: 'missing',
              name: 'Missing',
              entityIds: ['light.removed'],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('light.removed'), findsOneWidget);
    expect(find.byType(HomeAccessoryTile), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (name, size, scale, brightness) in [
    ('home-tablet', const Size(1366, 1024), 1.0, Brightness.light),
    ('home-tablet-dark', const Size(1366, 1024), 1.0, Brightness.dark),
    ('home-phone', const Size(390, 844), 1.0, Brightness.light),
    ('home-large-text', const Size(390, 844), 2.0, Brightness.dark),
  ]) {
    testWidgets('$name renders without overflow', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const previewDir = String.fromEnvironment('HOME_PREVIEW_DIR');
      if (previewDir.isNotEmpty) {
        final loader = FontLoader('Inter')
          ..addFont(rootBundle.load('assets/fonts/Inter-Variable.ttf'));
        await loader.load();
        final icons = FontLoader('packages/cupertino_icons/CupertinoIcons')
          ..addFont(
            rootBundle.load(
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
            ),
          );
        await icons.load();
      }
      final boundary = GlobalKey();
      await tester.pumpWidget(
        app(scale: scale, brightness: brightness, boundary: boundary),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (previewDir.isNotEmpty) {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$previewDir/$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
