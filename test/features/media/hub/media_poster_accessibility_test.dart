import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/media/hub/presentation/media_hub_screen.dart';
import 'package:larenor/features/media/hub/presentation/media_title_detail_screen.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_item_detail_screen.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_library_screen.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/poster_card.dart';

const _film = MediaTitle(
  identity: MediaIdentity(kind: MediaKind.movie, tmdbId: 1),
  title: 'Yıldızların Ötesindeki Yolculuk',
  availability: MediaAvailability.inLibrary,
);
const _item = JellyfinItem(
  id: 'film',
  name: 'Yıldızların Ötesindeki Yolculuk',
  type: 'Movie',
);

Future<void> _mount(
  WidgetTester tester,
  Widget screen, {
  String language = 'en',
  double width = 600,
  bool dark = false,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        jellyfinClientProvider.overrideWith((ref) => null),
        jellyfinLibraryItemsProvider('library')
            .overrideWith((ref) async => const [_item]),
        mediaLibraryIndexProvider.overrideWith(
          (ref) async => MediaLibraryIndex.empty,
        ),
        mediaHubRowsProvider.overrideWith(
          (ref) async => const [
            MediaRowData(id: MediaRowId.recentlyAdded, titles: [_film]),
          ],
        ),
      ],
      child: CupertinoApp(
        theme: larenorTheme(
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tabToPoster(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(PosterCard).first);
  for (var i = 0; i < 24; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<PosterCard>() !=
        null)
      return;
  }
  fail('The visible media poster cannot be reached with Tab.');
}

void main() {
  testWidgets('Media home poster opens the same detail with Tab and Enter', (
    tester,
  ) async {
    await _mount(tester, const MediaHubScreen());
    await _tabToPoster(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(MediaTitleDetailScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Jellyfin library poster opens detail with Tab and Space', (
    tester,
  ) async {
    await _mount(
      tester,
      const JellyfinLibraryScreen(parentId: 'library', title: 'Library'),
    );
    await _tabToPoster(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byType(JellyfinItemDetailScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      for (final dark in [false, true]) {
        testWidgets(
          'Library $language ${width.toInt()} 2x dark=$dark keeps caption glyph height',
          (tester) async {
            await _mount(
              tester,
              const JellyfinLibraryScreen(
                parentId: 'library',
                title: 'Library',
              ),
              language: language,
              width: width,
              dark: dark,
            );
            final text = find.descendant(
              of: find.byType(PosterCard),
              matching: find.text(_item.name),
            );
            final paragraph = tester.renderObject<RenderParagraph>(text);
            final needed = paragraph.getMaxIntrinsicHeight(
              paragraph.size.width,
            );
            expect(
              paragraph.size.height,
              greaterThanOrEqualTo(needed - .01),
              reason:
                  'The complete scaled caption line must fit below the poster.',
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
