import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/media/hub/presentation/media_hub_screen.dart';
import 'package:larenor/features/media/hub/presentation/media_title_detail_screen.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_client.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_series_screen.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const film = MediaTitle(
  identity: MediaIdentity(kind: MediaKind.movie, tmdbId: 1),
  title: 'A Quiet Orbit',
  availability: MediaAvailability.inLibrary,
  year: 2026,
  rating: 8.4,
  overview: 'One last journey beneath a sky full of possibilities.',
  jellyfinItemId: 'film',
);
const show = MediaTitle(
  identity: MediaIdentity(kind: MediaKind.tv, tmdbId: 2),
  title: 'Beyond the Pines',
  availability: MediaAvailability.inLibrary,
  jellyfinItemId: 'show',
  jellyfinSeriesId: 'show',
);

Widget app(Widget child, {JellyfinClient? client, double scale = 1}) =>
    ProviderScope(
      overrides: [
        jellyfinClientProvider.overrideWith((ref) => client),
        mediaLibraryIndexProvider.overrideWith(
          (ref) async => MediaLibraryIndex.empty,
        ),
        mediaHubRowsProvider.overrideWith(
          (ref) async => const [
            MediaRowData(id: MediaRowId.recentlyAdded, titles: [film, show]),
          ],
        ),
      ],
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: child,
      ),
    );

void main() {
  testWidgets('film and TV filters change the featured title and rows', (
    tester,
  ) async {
    await tester.pumpWidget(app(const MediaHubScreen()));
    await tester.pumpAndSettle();
    expect(find.text('A Quiet Orbit'), findsWidgets);
    await tester.tap(find.text('TV series').first);
    await tester.pumpAndSettle();
    expect(find.text('A Quiet Orbit'), findsNothing);
    expect(find.text('Beyond the Pines'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow screens retain controls at large text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(const MediaHubScreen(), scale: 1.5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'series action opens available episodes instead of a video container',
    (tester) async {
      final paths = <String>[];
      final client = JellyfinClient(
        config: const JellyfinConfig(
          baseUrl: 'http://jellyfin.test',
          userId: 'user',
          accessToken: 'test',
          deviceId: 'tablet',
        ),
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          final Object body = switch (request.url.path) {
            '/Users/user/Items/show' => {
              'Id': 'show',
              'Name': 'Beyond the Pines',
              'Type': 'Series',
            },
            '/Shows/show/Seasons' => {
              'Items': [
                {'Id': 'season-1', 'Name': 'Season 1', 'Type': 'Season'},
              ],
            },
            '/Shows/show/Episodes' => {
              'Items': [
                {
                  'Id': 'ep-1',
                  'Name': 'The Beginning',
                  'Type': 'Episode',
                  'ParentIndexNumber': 1,
                  'IndexNumber': 1,
                },
              ],
            },
            _ => {'Items': []},
          };
          return http.Response(jsonEncode(body), 200);
        }),
      );
      addTearDown(client.dispose);
      await tester.pumpWidget(
        app(const MediaTitleDetailScreen(title: show), client: client),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Episodes'));
      await tester.pumpAndSettle();
      expect(find.byType(JellyfinSeriesScreen), findsOneWidget);
      expect(find.text('The Beginning'), findsOneWidget);
      expect(paths.where((path) => path.contains('PlaybackInfo')), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tablet cinema layout', (tester) async {
    const outputPath = String.fromEnvironment('MEDIA_PREVIEW_PATH');
    if (outputPath.isNotEmpty) {
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
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      app(RepaintBoundary(key: boundary, child: const MediaHubScreen())),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (outputPath.isNotEmpty) {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(outputPath).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
