import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_item_detail_screen.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_library_screen.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/poster_card.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _folder = JellyfinItem(
  id: 'documentaries',
  name: 'Belgeseller',
  type: 'Folder',
);

Future<void> _mount(
  WidgetTester tester, {
  required double width,
  required String language,
  Object? libraryError,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        jellyfinClientProvider.overrideWith((ref) => null),
        jellyfinLibraryItemsProvider('library').overrideWith((ref) async {
          if (libraryError != null) throw libraryError;
          return const [_folder];
        }),
      ],
      child: CupertinoApp(
        theme: larenorTheme(),
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const JellyfinLibraryScreen(
          parentId: 'library',
          title: 'Library',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tabToPoster(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<PosterCard>() !=
        null) {
      return;
    }
  }
  fail('The Jellyfin library poster is not reachable with Tab.');
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('Jellyfin browse drill-down uses the shared tablet surface '
          '$language $width 2x', (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await _mount(tester, width: width, language: language);
          expect(find.byType(AppSurface), findsOneWidget);
          expect(tester.takeException(), isNull);

          final poster = find.byType(PosterCard);
          final posterNode = tester.getSemantics(poster);
          expect(posterNode.label, _folder.name);
          expect(posterNode.flagsCollection.isButton, isTrue);
          expect(posterNode.rect.shortestSide, greaterThanOrEqualTo(48));

          await _tabToPoster(tester);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(find.byType(JellyfinItemDetailScreen), findsOneWidget);
          expect(find.byType(AppSurface), findsOneWidget);
          final l10n = AppLocalizations.of(
            tester.element(find.byType(JellyfinItemDetailScreen)),
          );
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(2));
          final heading = find.byKey(
            const ValueKey('jellyfin-item-detail-title'),
          );
          final headingNode = tester.getSemantics(heading);
          expect(headingNode.label, _folder.name);
          expect(headingNode.flagsCollection.isHeader, isTrue);
          expect(headingNode.flagsCollection.isButton, isFalse);

          final browse = find.byKey(
            const ValueKey('jellyfin-item-primary-action'),
          );
          final browseNode = tester.getSemantics(browse);
          expect(browseNode.label, l10n.jellyfinBrowseButton);
          expect(browseNode.flagsCollection.isButton, isTrue);
          expect(browseNode.rect.width, greaterThanOrEqualTo(48));
          expect(browseNode.rect.height, greaterThanOrEqualTo(48));

          final browseLabel = find.descendant(
            of: browse,
            matching: find.text(l10n.jellyfinBrowseButton),
          );
          Focus.of(tester.element(browseLabel)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(JellyfinLibraryScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });

      testWidgets('Jellyfin read failure uses private shared status language '
          '$language $width 2x', (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await _mount(
            tester,
            width: width,
            language: language,
            libraryError: StateError('private upstream diagnostic'),
          );
          final l10n = AppLocalizations.of(
            tester.element(find.byType(JellyfinLibraryScreen)),
          );
          expect(find.text(l10n.mediaErrorUnreachable), findsOneWidget);
          expect(
            find.textContaining('private upstream diagnostic'),
            findsNothing,
          );
          final status = tester.getSemantics(
            find.byKey(const ValueKey('jellyfin-library-status')),
          );
          expect(status.label, l10n.mediaErrorUnreachable);
          expect(status.flagsCollection.isLiveRegion, isTrue);
          expect(find.byType(AppSurface), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
