import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/ambient/data/ambient_repository.dart';
import 'package:larenor/features/ambient/domain/ambient_settings.dart';
import 'package:larenor/features/ambient/presentation/ambient_screen.dart';
import 'package:larenor/features/ambient/presentation/ambient_settings_screen.dart';
import 'package:larenor/features/ambient/providers/ambient_providers.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/settings/domain/screen_program.dart';
import 'package:larenor/features/settings/presentation/screen_program_screen.dart';
import 'package:larenor/features/web_panel/domain/web_panel_options.dart';
import 'package:larenor/features/web_panel/presentation/web_panel_settings_screen.dart';
import 'package:larenor/features/wellbeing/providers/wellbeing_privacy_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => null;
}

class _Photos extends AmbientRepository {
  _Photos(this.bytes);
  final Uint8List bytes;
  @override
  Future<List<String>> list() async => ['a' * 64];
  @override
  Future<Uint8List> readPhoto(String id) async => bytes;
}

// Geometric, synthetic fixture, drawn locally; no household photos or network.
Future<Uint8List> _landscape() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 1366, 900),
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xff394868), Color(0xffc78876), Color(0xffe7b88d)],
      ).createShader(const Rect.fromLTWH(0, 0, 1366, 900)),
  );
  canvas.drawCircle(
    const Offset(920, 330),
    100,
    Paint()..color = const Color(0xffedcea0),
  );
  for (var i = 0; i < 3; i++) {
    final y = 610.0 + i * 90;
    canvas.drawPath(
      Path()
        ..moveTo(0, y)
        ..cubicTo(400, y - 280, 660, y + 200, 1366, y - 120)
        ..lineTo(1366, 900)
        ..lineTo(0, 900)
        ..close(),
      Paint()
        ..color = [
          const Color(0xff716574),
          const Color(0xff414955),
          const Color(0xff283c43),
        ][i],
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(1366, 900);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  for (final entry in [
    ('ambient-settings-phone', const Size(390, 844), false, 0),
    ('ambient-tablet-dark', const Size(1366, 900), true, 1),
    ('screen-program-phone', const Size(390, 1000), false, 2),
    ('web-panel-settings-tablet-dark', const Size(1024, 900), true, 3),
  ]) {
    testWidgets('${entry.$1} renders actual widgets with synthetic content', (
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
      final bytes = await tester.runAsync(_landscape);
      SharedPreferences.setMockInitialValues({
        AmbientSettings.preferenceKey: const AmbientSettings(
          photosEnabled: true,
        ).encode(),
        ScreenProgram.preferenceKey: ScreenProgram(
          enabled: true,
          rules: [
            ScreenProgramRule(
              id: 'night',
              name: 'Gece dinlenmesi',
              days: {1, 2, 3, 4, 5, 6, 7},
              startMinutes: 1320,
              endMinutes: 420,
              dim: true,
              awake: ScreenAwakeMode.systemTimeout,
            ),
            ScreenProgramRule(
              id: 'morning',
              name: 'Hafta içi sabah',
              days: {1, 2, 3, 4, 5},
              startMinutes: 420,
              endMinutes: 540,
              awake: ScreenAwakeMode.keepAwake,
            ),
          ],
        ).encode(),
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.view.physicalSize = entry.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ambientRepositoryProvider.overrideWithValue(_Photos(bytes!)),
            connectionConfigProvider.overrideWith(_Connection.new),
            publicHaEntitiesProvider.overrideWithValue(const AsyncData({})),
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
            home: switch (entry.$4) {
              0 => const AmbientSettingsScreen(),
              1 => const AmbientScreen(),
              2 => const ScreenProgramScreen(),
              _ => WebPanelSettingsScreen(
                initialTile: TileConfig(
                  id: 'preview',
                  type: TileType.webview,
                  x: 0,
                  y: 0,
                  width: 3,
                  height: 2,
                  title: 'Ev panosu',
                  url: 'https://panel.example.test/dashboard',
                  webPanel: WebPanelOptions(
                    additionalOrigins: ['https://login.example.test'],
                    textZoom: 125,
                  ),
                ),
              ),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(bytes),
          tester.element(find.byType(CupertinoApp)),
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
