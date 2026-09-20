import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_home_screen.dart';
import 'package:larenor/features/media/jellyfin/presentation/jellyfin_library_screen.dart';
import 'package:larenor/features/media/jellyfin/presentation/widgets/jellyfin_poster.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

class _FailingConnection extends JellyfinConnection {
  _FailingConnection(this.onRead);

  final VoidCallback onRead;

  @override
  Future<JellyfinConfig?> build() async {
    onRead();
    throw StateError('private upstream diagnostic');
  }
}

class _ConnectedConnection extends JellyfinConnection {
  @override
  Future<JellyfinConfig?> build() async => const JellyfinConfig(
    baseUrl: 'https://jellyfin.fixture.invalid',
    userId: 'fixture-user',
    accessToken: 'fixture-token',
    deviceId: 'fixture-device',
  );
}

Future<void> _tabToRetry(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final button = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<CupertinoButton>();
    if (button?.key == const ValueKey('jellyfin-home-retry')) return;
  }
  fail('The Jellyfin retry action is not reachable with Tab.');
}

void main() {
  for (final width in [600.0, 1280.0]) {
    testWidgets('Jellyfin failure uses shared live tablet state and retry '
        '$width 2x', (tester) async {
      final semantics = tester.ensureSemantics();
      var reads = 0;
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              jellyfinConnectionProvider.overrideWith(
                () => _FailingConnection(() => reads++),
              ),
            ],
            child: CupertinoApp(
              theme: larenorTheme(),
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const JellyfinHomeScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l10n = AppLocalizations.of(
          tester.element(find.byType(JellyfinHomeScreen)),
        );

        expect(find.byType(AppSurface), findsOneWidget);
        expect(find.text(l10n.mediaErrorUnreachable), findsOneWidget);
        expect(
          find.textContaining('private upstream diagnostic'),
          findsNothing,
        );
        final status = tester.getSemantics(
          find.byKey(const ValueKey('jellyfin-home-status')),
        );
        expect(status.label, l10n.mediaErrorUnreachable);
        expect(status.flagsCollection.isLiveRegion, isTrue);

        final retry = find.byKey(const ValueKey('jellyfin-home-retry'));
        final retryNode = tester.getSemantics(retry);
        expect(retryNode.label, l10n.commonRetry);
        expect(retryNode.flagsCollection.isButton, isTrue);
        expect(retryNode.rect.height, greaterThanOrEqualTo(48));

        await _tabToRetry(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(reads, 2);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets('${locale.languageCode} Jellyfin hierarchy fits '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                jellyfinConnectionProvider.overrideWith(
                  _ConnectedConnection.new,
                ),
                jellyfinClientProvider.overrideWith((_) => null),
                jellyfinResumeItemsProvider.overrideWith(
                  (_) async => const [
                    JellyfinItem(
                      id: 'resume',
                      name: 'Continue fixture',
                      type: 'Movie',
                    ),
                  ],
                ),
                jellyfinLatestItemsProvider.overrideWith(
                  (_) async => const [
                    JellyfinItem(
                      id: 'latest',
                      name: 'Latest fixture',
                      type: 'Movie',
                    ),
                  ],
                ),
                jellyfinLibrariesProvider.overrideWith(
                  (_) async => const [
                    JellyfinItem(
                      id: 'library',
                      name: 'Living Room Library',
                      type: 'CollectionFolder',
                    ),
                  ],
                ),
              ],
              child: CupertinoApp(
                theme: larenorTheme(),
                locale: locale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: const JellyfinHomeScreen(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final l10n = await AppLocalizations.delegate.load(locale);

          expect(find.byType(AppSurface), findsOneWidget);
          for (final label in [
            l10n.jellyfinContinueWatching,
            l10n.jellyfinRecentlyAdded,
            l10n.jellyfinLibrariesHeader,
          ]) {
            final heading = find.text(label);
            expect(
              tester.getSemantics(heading).flagsCollection.isHeader,
              isTrue,
            );
            expect(
              tester.getSemantics(heading).flagsCollection.isButton,
              isFalse,
            );
          }
          expect(
            find.ancestor(
              of: find.text(l10n.jellyfinLibrariesHeader),
              matching: find.byType(SettingsSection),
            ),
            findsOneWidget,
          );

          final posterActions = find.descendant(
            of: find.byType(JellyfinPoster),
            matching: find.byType(CupertinoButton),
          );
          for (var i = 0; i < posterActions.evaluate().length; i++) {
            final rect = tester.getRect(posterActions.at(i));
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
          }

          final libraryAction = find.byKey(
            const ValueKey('jellyfin-library-library'),
          );
          await tester.ensureVisible(libraryAction);
          expect(
            tester.getRect(libraryAction).height,
            greaterThanOrEqualTo(48),
          );
          final accountAction = find.byKey(
            const ValueKey('service-account-action'),
          );
          await tester.scrollUntilVisible(
            accountAction,
            300,
            scrollable: find.descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            ).first,
            maxScrolls: 10,
          );
          expect(
            tester.getRect(accountAction).height,
            greaterThanOrEqualTo(48),
          );
          await tester.ensureVisible(libraryAction);
          Focus.of(tester.element(find.text('Living Room Library')))
              .requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(JellyfinLibraryScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
