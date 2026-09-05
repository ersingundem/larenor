import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/settings/presentation/window_panel_screen.dart';
import 'package:larenor/features/settings/providers/window_profile_provider.dart';
import 'package:larenor/features/wellbeing/domain/wellbeing_models.dart';
import 'package:larenor/features/wellbeing/presentation/wellbeing_screen.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../features/wellbeing/wellbeing_controller_test.dart'
    show FakeNative, MemoryStore;

class _WindowStore implements WindowProfileStore {
  @override
  Future<Object?> read() async => 'adaptive';
  @override
  Future<void> write(WindowProfile profile) async =>
      throw StateError('Preview is read-only');
}

void main() {
  for (final entry in [
    ('window-panel-phone', const Size(390, 844), false, false),
    ('window-panel-desktop-dark', const Size(1366, 768), true, false),
    ('wellbeing-phone', const Size(390, 844), false, true),
    ('wellbeing-tablet-dark', const Size(1366, 1024), true, true),
  ]) {
    testWidgets('${entry.$1} uses real widgets and synthetic local fixtures', (
      tester,
    ) async {
      const out = String.fromEnvironment('DESIGN_PREVIEW_DIR');
      if (out.isNotEmpty) {
        await tester.runAsync(() async {
          final font = await rootBundle.load('assets/fonts/Inter-Variable.ttf');
          for (final family in [
            'Inter',
            'CupertinoSystemText',
            'CupertinoSystemDisplay',
          ]) {
            await (FontLoader(family)..addFont(Future.value(font))).load();
          }
          await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
                rootBundle.load(
                  'packages/cupertino_icons/assets/CupertinoIcons.ttf',
                ),
              ))
              .load();
        });
      }
      tester.view.physicalSize = entry.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final native = FakeNative();
      final store = MemoryStore()
        ..settings = WellbeingSettings(
          enabled: true,
          profileLabel: 'Örnek profil',
          nativeMetrics: {WellbeingMetric.bodyMass, WellbeingMetric.steps},
        );
      final now = DateTime(2026, 9, 5, 14, 30);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            windowProfileStoreProvider.overrideWithValue(_WindowStore()),
            windowPolicySnapshotProvider.overrideWith(
              (_) => Stream.value(
                WindowPolicySnapshot(
                  supported: true,
                  isResumed: true,
                  hasWindowFocus: true,
                  effectiveMode: WindowEffectiveMode.adaptive,
                  isMultiWindow: entry.$3,
                  isExternalDisplay: entry.$3,
                  captionVisible: entry.$3,
                  imeVisible: false,
                  statusBarVisible: true,
                  navigationBarVisible: true,
                  lockTaskState: WindowLockTaskState.none,
                  lockTaskPermitted: false,
                ),
              ),
            ),
            wellbeingAccessProvider.overrideWithValue(
              WellbeingAccessSession(isCurrent: () => true),
            ),
            wellbeingStoreProvider.overrideWithValue(store),
            wellbeingNativeApiProvider.overrideWithValue(native),
            haWellbeingApiProvider.overrideWith((_) => null),
            wellbeingProvider.overrideWith(
              (_) => Stream.value(
                WellbeingSnapshot(
                  statuses: {WellbeingSource.healthConnect: native.status},
                  results: [
                    WellbeingReadResult(
                      source: WellbeingSource.healthConnect,
                      metric: WellbeingMetric.bodyMass,
                      state: WellbeingReadState.data,
                      readAt: now,
                      measurements: [
                        WellbeingMeasurement(
                          source: WellbeingSource.healthConnect,
                          metric: WellbeingMetric.bodyMass,
                          value: 70.2,
                          unit: 'kg',
                          profileLabel: 'Örnek profil',
                          readAt: now,
                          measuredAt: now.subtract(const Duration(hours: 6)),
                          originName: 'Sentetik tartı kaydı',
                        ),
                      ],
                    ),
                    WellbeingReadResult(
                      source: WellbeingSource.healthConnect,
                      metric: WellbeingMetric.steps,
                      state: WellbeingReadState.data,
                      readAt: now,
                      measurements: [
                        WellbeingMeasurement(
                          source: WellbeingSource.healthConnect,
                          metric: WellbeingMetric.steps,
                          value: 6240,
                          unit: 'steps',
                          profileLabel: 'Örnek profil',
                          readAt: now,
                          measuredAt: DateTime(2026, 9, 5),
                          intervalEnd: now,
                          originName: 'Sentetik günlük toplam',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          child: CupertinoApp(
            locale: const Locale('tr'),
            theme: larenorTheme(
              brightness: entry.$3 ? Brightness.dark : Brightness.light,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) =>
                RepaintBoundary(key: boundary, child: child!),
            home: entry.$4
                ? WellbeingScreen(onLock: () {}, onExit: () {})
                : const WindowPanelScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (entry.$4) {
        final recent = find.text(
          AppLocalizations.of(tester.element(find.byType(WellbeingScreen)))
              .wellbeingRecent,
        );
        await tester.scrollUntilVisible(
          recent,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(tester.element(recent), alignment: 0.1);
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      expect(native.probes + native.permissions + native.reads, 0);
      if (out.isNotEmpty) {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('$out/${entry.$1}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
