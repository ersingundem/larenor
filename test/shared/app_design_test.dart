import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/shared/theme/app_colors.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/media/hub/presentation/media_hub_screen.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final dark in [false, true]) {
    for (final media in [false, true]) {
      for (final phone in [false, true]) {
        final name =
            '${media ? 'media' : 'settings'}-${phone ? 'phone' : 'tablet'}${dark ? '-dark' : ''}';
        testWidgets('$name follows shared appearance and remains navigable', (
          tester,
        ) async {
          SharedPreferences.setMockInitialValues({});
          const out = String.fromEnvironment('DESIGN_PREVIEW_DIR');
          if (out.isNotEmpty) {
            await tester.runAsync(() async {
              final data = await rootBundle.load(
                'assets/fonts/Inter-Variable.ttf',
              );
              for (final family in [
                'Inter',
                'CupertinoSystemText',
                'CupertinoSystemDisplay',
              ]) {
                await (FontLoader(family)..addFont(Future.value(data))).load();
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
          tester.view.physicalSize = phone
              ? const Size(390, 844)
              : const Size(1366, 1024);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                jellyfinClientProvider.overrideWith((ref) => null),
                mediaHubRowsProvider.overrideWith(
                  (ref) async => const [
                    MediaRowData(
                      id: MediaRowId.recentlyAdded,
                      titles: [
                        MediaTitle(
                          identity: MediaIdentity(
                            kind: MediaKind.movie,
                            tmdbId: 1,
                          ),
                          title: 'A Quiet Orbit',
                          availability: MediaAvailability.inLibrary,
                          year: 2026,
                          rating: 8.4,
                          overview: 'Yıldızların altında yeni bir yolculuk.',
                        ),
                        MediaTitle(
                          identity: MediaIdentity(
                            kind: MediaKind.tv,
                            tmdbId: 2,
                          ),
                          title: 'Beyond the Pines',
                          availability: MediaAvailability.inLibrary,
                        ),
                      ],
                    ),
                  ],
                ),
              ],
              child: CupertinoApp(
                theme: larenorTheme(
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
                locale: const Locale('tr'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) =>
                    RepaintBoundary(key: boundary, child: child!),
                home: media
                    ? const MediaHubScreen()
                    : const SettingsSplitScreen(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (!media) {
            await tester.tap(find.text('Home Assistant').first);
            await tester.pumpAndSettle();
            expect(find.text('Eylemler'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          final surfaceContext = tester.element(find.byType(AppSurface).first);
          expect(
            CupertinoTheme.of(surfaceContext).brightness,
            dark ? Brightness.dark : Brightness.light,
          );
          expect(
            AppColors.canvas.resolveFrom(surfaceContext).toARGB32(),
            (dark ? AppColors.canvas.darkColor : AppColors.canvas.color)
                .toARGB32(),
          );
          if (out.isNotEmpty) {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await render.toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File('$out/$name.png')
                  .writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
        });
      }
    }
  }
}
