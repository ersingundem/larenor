import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_item_detail_screen.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_library_screen.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/poster_card.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _movie = JellyfinItem(id: 'movie', name: 'Arrival', type: 'Movie');

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        jellyfinClientProvider.overrideWith((ref) => null),
        jellyfinLibraryItemsProvider('library')
            .overrideWith((ref) async => const [_movie]),
      ],
      child: CupertinoApp(
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
      testWidgets('$language library action is accessible at ${width}px 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await _mount(tester, language: language, width: width);

        expect(find.byType(ServiceRootScaffold), findsOneWidget);
        expect(find.byType(SettingsSection), findsOneWidget);
        expect(find.byType(SettingsActionTile), findsOneWidget);
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('jellyfin-library-header')),
              )
              .flagsCollection
              .isHeader,
          isTrue,
        );
        final refresh = find.byKey(const ValueKey('jellyfin-library-refresh'));
        expect(
          tester.widget<CupertinoButton>(refresh).minimumSize,
          const Size(48, 48),
        );

        final poster = find.byType(PosterCard);
        expect(tester.getSemantics(poster).flagsCollection.isButton, isTrue);
        await _tabToPoster(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(find.byType(JellyfinItemDetailScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
}
