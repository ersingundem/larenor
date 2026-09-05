import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
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

bool _fontsLoaded = false;

Future<GlobalKey> _mount(
  WidgetTester tester,
  Widget screen, {
  String language = 'en',
  double width = 600,
  bool dark = false,
  AppInteractionController? interaction,
  int itemCount = 1,
}) async {
  if (!_fontsLoaded) {
    await tester.runAsync(() async {
      final data = await rootBundle.load('assets/fonts/Inter-Variable.ttf');
      for (final family in [
        'Inter',
        'CupertinoSystemText',
        'CupertinoSystemDisplay',
      ]) {
        await (FontLoader(family)..addFont(Future.value(data))).load();
      }
      await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
            rootBundle.load(
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
            ),
          ))
          .load();
    });
    _fontsLoaded = true;
  }
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final boundary = GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        jellyfinClientProvider.overrideWith((ref) => null),
        jellyfinLibraryItemsProvider('library').overrideWith(
          (ref) async => List.generate(
            itemCount,
            (index) => index == 0
                ? _item
                : _item.copyWith(id: 'film-$index', name: 'Arşiv ${index + 1}'),
          ),
        ),
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
          child: RepaintBoundary(
            key: boundary,
            child: interaction == null
                ? child!
                : AppInteractionScope(controller: interaction, child: child!),
          ),
        ),
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    AppLocalizations.of(tester.element(find.byType(screen.runtimeType)))
        .localeName,
    language,
  );
  return boundary;
}

Future<void> _tabToPoster(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(PosterCard).first);
  for (var i = 0; i < 24; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<PosterCard>() !=
        null) {
      return;
    }
  }
  fail('The visible media poster cannot be reached with Tab.');
}

void main() {
  for (final hub in [false, true]) {
    testWidgets(
      '${hub ? 'Media home' : 'Library'} old native action cannot navigate after window retirement',
      (tester) async {
        final interaction = AppInteractionController();
        await _mount(
          tester,
          hub
              ? const MediaHubScreen()
              : const JellyfinLibraryScreen(
                  parentId: 'library',
                  title: 'Library',
                ),
          interaction: interaction,
        );
        await tester.ensureVisible(find.byType(PosterCard).first);
        final button = tester.widget<CupertinoButton>(
          find.descendant(
            of: find.byType(PosterCard).first,
            matching: find.byType(CupertinoButton),
          ),
        );
        final callback = button.onPressed!;
        interaction.setActive(false);
        callback();
        await tester.pump();
        interaction.setActive(true);
        await tester.pump();
        callback();
        await tester.pumpAndSettle();
        expect(find.byType(MediaTitleDetailScreen), findsNothing);
        expect(find.byType(JellyfinItemDetailScreen), findsNothing);
        await _tabToPoster(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(
          hub
              ? find.byType(MediaTitleDetailScreen)
              : find.byType(JellyfinItemDetailScreen),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        interaction.dispose();
      },
    );
  }

  testWidgets(
    'Library keyboard visits and scrolls every poster then Shift Tab returns',
    (tester) async {
      await _mount(
        tester,
        const JellyfinLibraryScreen(parentId: 'library', title: 'Library'),
        itemCount: 40,
      );
      await _tabToPoster(tester);
      for (var index = 1; index < 40; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final poster = FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<PosterCard>();
        expect(poster?.title, 'Arşiv ${index + 1}');
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<PosterCard>()
            ?.title,
        'Arşiv 39',
      );
      expect(find.text('Arşiv 39').hitTestable(), findsOneWidget);
    },
  );

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
            final boundary = await _mount(
              tester,
              const JellyfinLibraryScreen(
                parentId: 'library',
                title: 'Library',
              ),
              language: language,
              width: width,
              dark: dark,
              itemCount: 12,
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
            final lastText = tester.renderObject<RenderParagraph>(
              find.text('Arşiv 12'),
            );
            expect(
              lastText.size.height,
              greaterThanOrEqualTo(
                lastText.getMaxIntrinsicHeight(lastText.size.width) - .01,
              ),
            );
            expect(tester.takeException(), isNull);
            await _tabToPoster(tester);
            await tester.pumpAndSettle();
            final poster = find.byType(PosterCard).first;
            final button = find.descendant(
              of: poster,
              matching: find.byType(CupertinoButton),
            );
            final control = tester.widget<CupertinoButton>(button);
            final context = tester.element(button);
            final background = CupertinoTheme.of(context)
                .scaffoldBackgroundColor;
            final focus = CupertinoDynamicColor.resolve(
              control.focusColor!,
              context,
            );
            final fg = focus.computeLuminance();
            final bg = CupertinoDynamicColor.resolve(
              background,
              context,
            ).computeLuminance();
            expect(
              ((fg > bg ? fg : bg) + .05) / ((fg < bg ? fg : bg) + .05),
              greaterThanOrEqualTo(3),
            );
            final cardBounds = tester.getRect(poster);
            final focusBounds = tester.getRect(button).inflate(3.5);
            expect(cardBounds.contains(focusBounds.topLeft), isTrue);
            expect(cardBounds.contains(focusBounds.bottomRight), isTrue);
            expect(
              tester.getSize(button).shortestSide,
              greaterThanOrEqualTo(48),
            );
            const output = String.fromEnvironment('MEDIA_A11Y_PREVIEW_DIR');
            if (output.isNotEmpty && language == 'tr' && width == 600) {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              await tester.runAsync(() async {
                final image = await render.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await Directory(output).create(recursive: true);
                await File(
                  '$output/library-tr-600-2x-${dark ? 'dark' : 'light'}.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
          },
        );
      }
    }
  }
}
