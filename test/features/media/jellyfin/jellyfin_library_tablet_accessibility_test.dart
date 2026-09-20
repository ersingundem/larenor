import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_item_detail_screen.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_library_screen.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/poster_card.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _movie = JellyfinItem(id: 'movie', name: 'Arrival', type: 'Movie');

class _Connection extends JellyfinConnection {
  _Connection(this.config);

  JellyfinConfig config;

  @override
  Future<JellyfinConfig?> build() async => config;

  void replace(JellyfinConfig value) {
    config = value;
    state = AsyncData(value);
  }
}

const _accountA = JellyfinConfig(
  baseUrl: 'https://media-a.example',
  userId: 'a',
  accessToken: 'test-token-a',
  deviceId: 'tablet',
);

const _accountB = JellyfinConfig(
  baseUrl: 'https://media-b.example',
  userId: 'b',
  accessToken: 'test-token-b',
  deviceId: 'tablet',
);

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  VoidCallback? onLibraryRead,
  _Connection? connection,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        jellyfinConnectionProvider.overrideWith(
          () => connection ?? _Connection(_accountA),
        ),
        jellyfinClientProvider.overrideWith((ref) => null),
        jellyfinLibraryItemsProvider('library').overrideWith((ref) async {
          onLibraryRead?.call();
          return const [_movie];
        }),
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
  testWidgets('captured library refresh cannot cross result authority', (
    tester,
  ) async {
    var reads = 0;
    await _mount(
      tester,
      language: 'en',
      width: 600,
      onLibraryRead: () => reads++,
    );
    expect(reads, 1);
    final refresh = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('jellyfin-library-refresh')),
        )
        .onPressed!;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(JellyfinLibraryScreen)),
    );
    container.invalidate(jellyfinLibraryItemsProvider('library'));
    await tester.pumpAndSettle();
    expect(reads, 2);

    refresh();
    await tester.pumpAndSettle();

    expect(reads, 2);
  });

  testWidgets('account change expires the library route and old actions', (
    tester,
  ) async {
    var reads = 0;
    final connection = _Connection(_accountA);
    await _mount(
      tester,
      language: 'en',
      width: 600,
      onLibraryRead: () => reads++,
      connection: connection,
    );
    final refresh = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('jellyfin-library-refresh')),
        )
        .onPressed!;
    final open = tester
        .widget<CupertinoButton>(
          find.descendant(
            of: find.byType(PosterCard),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;

    connection.replace(_accountB);
    await tester.pumpAndSettle();
    refresh();
    open();
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(JellyfinLibraryScreen)),
    );
    expect(reads, 1);
    expect(find.text(l10n.mediaAccountChanged), findsOneWidget);
    expect(find.byType(PosterCard), findsNothing);
    expect(find.byType(JellyfinItemDetailScreen), findsNothing);
  });

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
