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
import 'package:larenor/features/media/ha_playback/domain/ha_media_inventory.dart';
import 'package:larenor/features/media/local_audio/domain/local_audio_models.dart';
import 'package:larenor/features/media/local_audio/presentation/local_audio_screen.dart';
import 'package:larenor/features/media/local_audio/presentation/playback_power_screen.dart';
import 'package:larenor/features/media/local_audio/providers/local_audio_providers.dart';
import 'package:larenor/features/media/music/domain/music_models.dart';
import 'package:larenor/features/media/music/presentation/music_center_screen.dart';
import 'package:larenor/features/media/music/providers/music_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../features/media/local_audio/local_audio_ui_fixture.dart';

void main() {
  for (final entry in [
    ('music-outputs-phone', const Size(390, 844), false, 0),
    ('music-library-tablet-dark', const Size(1366, 1024), true, 1),
    ('local-audio-phone', const Size(390, 844), false, 2),
    ('playback-power-tablet-dark', const Size(1366, 1024), true, 3),
  ]) {
    testWidgets('${entry.$1} renders real widgets with synthetic local data', (
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
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.view.physicalSize = entry.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final generation = Object();
      final now = DateTime.utc(2026, 9, 5, 14, 30);
      final bridge = FakeLocalAudioBridge()
        ..current = const LocalAudioSnapshot(
          supported: true,
          phase: LocalAudioPhase.ready,
          sourceId: 'preview-audio',
          title: 'Akşam seçkisi',
          artist: 'Yerel ses örneği',
          album: 'Larenor önizlemesi',
          isPlaying: true,
          position: Duration(minutes: 1, seconds: 28),
          duration: Duration(minutes: 4, seconds: 12),
          canPause: true,
          canSeek: true,
          canStop: true,
        );
      addTearDown(bridge.events.close);
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
            musicAccountGenerationProvider.overrideWith((ref) => generation),
            musicDiscoveryProvider.overrideWith(
              (ref) async => MusicDiscovery(
                accountGeneration: generation,
                readAt: now,
                entries: [
                  const MusicAssistantEntry(
                    id: 'preview-music',
                    title: 'Ev müzik arşivi',
                    state: 'loaded',
                    disabled: false,
                  ),
                ],
                services: MusicReadService.values.toSet(),
                inventory: HaMediaInventory(
                  readAt: now,
                  registryAvailable: true,
                  services: const {},
                  targets: [
                    const HaMediaTarget(
                      entityId: 'media_player.living_room',
                      name: 'Salon HomePod',
                      state: 'playing',
                      supportedFeatures: 512,
                      enabled: true,
                      platform: 'apple_tv',
                      deviceClass: 'speaker',
                      registryId: 'preview-speaker',
                      mediaTitle: 'Akşam seçkisi',
                      mediaArtist: 'Ev müzik arşivi',
                    ),
                    const HaMediaTarget(
                      entityId: 'media_player.kitchen',
                      name: 'Mutfak hoparlörü',
                      state: 'idle',
                      supportedFeatures: 512,
                      enabled: true,
                      platform: 'cast',
                      deviceClass: 'speaker',
                      registryId: 'preview-kitchen',
                    ),
                  ],
                ),
              ),
            ),
            musicLibraryProvider.overrideWith(
              (ref, query) async => MusicRead(
                readAt: now,
                value: MusicLibraryPage(
                  type: query.type,
                  offset: query.offset,
                  limit: query.limit,
                  items: [
                    for (final title in [
                      'Akşam esintisi',
                      'Şehrin ritmi',
                      'Güneş doğarken',
                      'Sessiz sokaklar',
                      'Yolculuk',
                      'Birlikte',
                    ])
                      MusicMediaItem(
                        type: query.type,
                        reference: const MusicMediaReference(
                          'library://track/preview',
                        ),
                        name: title,
                        version: '',
                        artists: const ['Örnek sanatçı'],
                        album: 'Ev seçkisi',
                      ),
                  ],
                ),
              ),
            ),
            localAudioBridgeProvider.overrideWithValue(bridge),
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
              2 => const LocalAudioScreen(),
              3 => const PlaybackPowerScreen(),
              _ => const MusicCenterScreen(),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (entry.$4 == 1) {
        await tester.tap(find.text('Kütüphane'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Music Assistant bağlantısı seç'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ev müzik arşivi'));
        await tester.pumpAndSettle();
        expect(find.text('Akşam esintisi'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      expect(bridge.plays, isEmpty);
      expect(bridge.commands, isEmpty);
      expect(bridge.batteryOpens + bridge.notificationOpens, 0);
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
    });
  }
}
