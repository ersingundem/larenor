import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/domain/dashboard_card_size.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/presentation/dashboard_card_editor_screen.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/energy/data/energy_controller.dart';
import 'package:larenor/features/energy/data/energy_period.dart';
import 'package:larenor/features/energy/data/energy_repository.dart';
import 'package:larenor/features/energy/domain/energy_models.dart';
import 'package:larenor/features/energy/domain/maintenance_models.dart';
import 'package:larenor/features/energy/presentation/energy_maintenance_screen.dart';
import 'package:larenor/features/energy/providers/energy_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_widget_picker_screen.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../features/energy/energy_fixture.dart';

final _now = DateTime.utc(2026, 9, 5, 12, 30);
EnergySnapshot _energy() {
  final period = buildEnergyPeriod('Europe/Istanbul', _now, EnergyRange.today);
  return EnergySnapshot(
    energyConfigured: true,
    readAt: _now,
    period: period,
    meters: [
      for (final item in [
        (EnergyRole.gridImport, 'Şebeke tüketimi', 8.42),
        (EnergyRole.solarProduction, 'Güneş panelleri', 5.16),
        (EnergyRole.deviceConsumption, 'Çalışma odası', 1.28),
      ])
        EnergyMeterReading(
          definition: EnergyMeterDefinition(
            statisticId: 'sensor.${item.$1.name}',
            role: item.$1,
          ),
          name: item.$2,
          unit: 'kWh',
          daily: [
            EnergyDayReading(
              window: period.days.single,
              reportedValue: item.$3,
              expectedHours: 15,
              receivedHours: 15,
              hasBaseline: true,
              issues: {EnergyCoverageIssue.ongoing},
            ),
          ],
        ),
    ],
  );
}

class _Entities extends Entities {
  @override
  Future<Map<String, HaEntity>> build() async => {
    for (final row in [
      ('light.living', 'Salon aydınlatması', 'on'),
      ('climate.living', 'Salon iklimlendirme', 'heat'),
      ('media_player.tv', 'Salon televizyonu', 'off'),
      ('sensor.temperature', 'Oda sıcaklığı', '23.5'),
    ])
      row.$1: HaEntity(
        entityId: row.$1,
        state: row.$3,
        attributes: {'friendly_name': row.$2},
      ),
  };
}

void main() {
  final cases = [
    (
      name: 'energy-phone',
      size: const Size(390, 844),
      dark: false,
      page: const EnergyMaintenanceScreen(),
    ),
    (
      name: 'energy-tablet-dark',
      size: const Size(1366, 1024),
      dark: true,
      page: const EnergyMaintenanceScreen(),
    ),
    (
      name: 'keenetic-widget-picker-phone',
      size: const Size(390, 844),
      dark: false,
      page: const KeeneticWidgetPickerScreen(),
    ),
    (
      name: 'dashboard-card-editor-tablet-dark',
      size: const Size(1366, 1024),
      dark: true,
      page: const DashboardCardEditorScreen(
        mode: DashboardEditorMode.room,
        roomId: 'living',
      ),
    ),
  ];
  for (final entry in cases) {
    testWidgets(
      '${entry.name} renders actual screens using local synthetic data',
      (tester) async {
        const out = String.fromEnvironment('DESIGN_PREVIEW_DIR');
        if (out.isNotEmpty) {
          await tester.runAsync(() async {
            final font = await rootBundle.load(
              'assets/fonts/Inter-Variable.ttf',
            );
            for (final family in [
              'Inter',
              'CupertinoSystemText',
              'CupertinoSystemDisplay',
            ]) {
              await (FontLoader(family)..addFont(Future.value(font))).load();
            }
            await (FontLoader('packages/cupertino_icons/CupertinoIcons')
                  ..addFont(
                    rootBundle.load(
                      'packages/cupertino_icons/assets/CupertinoIcons.ttf',
                    ),
                  ))
                .load();
          });
        }
        tester.view.physicalSize = entry.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              connectionConfigProvider.overrideWithBuild(
                (ref, notifier) async => const HaConnectionConfig(
                  baseUrl: 'https://preview.invalid',
                  token: 'preview-fixture',
                ),
              ),
              energyProvider.overrideWith(
                (_) => Stream.value(EnergyViewState(snapshot: _energy())),
              ),
              energyControllerProvider.overrideWith((ref) {
                final controller = EnergyController(
                  repository: EnergyRepository(api: FakeEnergyApi()),
                );
                ref.onDispose(controller.dispose);
                return controller;
              }),
              maintenanceProvider.overrideWith(
                (_, scope) => MaintenanceSnapshot(
                  scope: scope,
                  checkedEntities: 22,
                  items: [
                    MaintenanceItem(
                      entityId: 'sensor.door_battery',
                      name: 'Giriş kapısı sensörü',
                      kinds: {MaintenanceKind.lowBattery},
                      batteryPercent: 16,
                    ),
                  ],
                ),
              ),
              proxmoxConnectionProvider.overrideWithBuild(
                (ref, notifier) async => null,
              ),
              keeneticConnectionProvider.overrideWithBuild(
                (ref, notifier) async => null,
              ),
              entitiesProvider.overrideWith(_Entities.new),
              dashboardLayoutProvider.overrideWithBuild(
                (ref, notifier) async => const DashboardLayout(
                  rooms: [
                    DashboardRoom(
                      id: 'living',
                      name: 'Salon',
                      entityIds: [
                        'light.living',
                        'climate.living',
                        'media_player.tv',
                        'sensor.temperature',
                      ],
                    ),
                  ],
                  entityCardSizes: {
                    'light.living': DashboardCardSize.medium,
                    'climate.living': DashboardCardSize.large,
                  },
                ),
              ),
            ],
            child: CupertinoApp(
              theme: larenorTheme(
                brightness: entry.dark ? Brightness.dark : Brightness.light,
              ),
              locale: const Locale('tr'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (_, child) =>
                  RepaintBoundary(key: boundary, child: child!),
              home: Consumer(
                builder: (context, ref, _) {
                  if (entry.page is DashboardCardEditorScreen) {
                    final entities = ref.watch(entitiesProvider);
                    if (entities.isLoading) return const SizedBox.shrink();
                  }
                  return entry.page;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (out.isNotEmpty) {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await render.toImage();
            try {
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File('$out/${entry.name}.png')
                  .writeAsBytes(png!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
      },
    );
  }
}
