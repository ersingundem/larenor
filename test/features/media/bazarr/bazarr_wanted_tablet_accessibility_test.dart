import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/media/bazarr/data/bazarr_client.dart';
import 'package:larenor/features/media/bazarr/data/bazarr_config.dart';
import 'package:larenor/features/media/bazarr/data/models/bazarr_wanted_item.dart';
import 'package:larenor/features/media/bazarr/presentation/bazarr_home_screen.dart';
import 'package:larenor/features/media/bazarr/providers/bazarr_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _config = BazarrConfig(
  baseUrl: 'http://127.0.0.1:6767',
  apiKey: 'fixture',
);

const _movie = BazarrWantedItem(
  radarrId: 42,
  seriesId: null,
  episodeId: null,
  title: 'Arrival',
  missingLanguages: [BazarrMissingLanguage(code: 'en', name: 'English')],
);

class _Connection extends BazarrConnection {
  @override
  Future<BazarrConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    return _config;
  }
}

Widget _tabletApp(Locale locale) => CupertinoApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: const BazarrHomeScreen(),
);

void main() {
  testWidgets('captured subtitle search cannot cross Bazarr authority', (
    tester,
  ) async {
    final oldRequests = <http.Request>[];
    final replacementRequests = <http.Request>[];
    BazarrClient client(List<http.Request> requests) => BazarrClient(
      config: _config,
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
    );
    final oldClient = client(oldRequests);
    final replacementClient = client(replacementRequests);
    addTearDown(oldClient.dispose);
    addTearDown(replacementClient.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bazarrConnectionProvider.overrideWith(_Connection.new),
          bazarrClientProvider.overrideWith((_) => oldClient),
          bazarrMissingMoviesProvider.overrideWith((_) async => const [_movie]),
          bazarrMissingEpisodesProvider.overrideWith((_) async => const []),
        ],
        child: _tabletApp(const Locale('en')),
      ),
    );
    await tester.pumpAndSettle();
    final search = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('bazarr-wanted-movie-42-search')),
        )
        .onPressed!;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BazarrHomeScreen)),
    );
    container.updateOverrides([
      bazarrConnectionProvider.overrideWith(_Connection.new),
      bazarrClientProvider.overrideWith((_) => replacementClient),
      bazarrMissingMoviesProvider.overrideWith((_) async => const [_movie]),
      bazarrMissingEpisodesProvider.overrideWith((_) async => const []),
    ]);
    await tester.pumpAndSettle();

    search();
    await tester.pumpAndSettle();

    expect(oldRequests, isEmpty);
    expect(replacementRequests, isEmpty);
  });

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets('${locale.languageCode} wanted hierarchy fits '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final requests = <http.Request>[];
        final client = BazarrClient(
          config: _config,
          httpClient: MockClient((request) async {
            requests.add(request);
            return http.Response('{}', 200);
          }),
        );
        addTearDown(client.dispose);
        var movieReads = 0;
        var episodeReads = 0;

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                bazarrConnectionProvider.overrideWith(_Connection.new),
                bazarrClientProvider.overrideWith((_) => client),
                bazarrMissingMoviesProvider.overrideWith((_) async {
                  movieReads++;
                  return const [_movie];
                }),
                bazarrMissingEpisodesProvider.overrideWith((_) async {
                  episodeReads++;
                  return const [];
                }),
              ],
              child: _tabletApp(locale),
            ),
          );
          await tester.pumpAndSettle();
          final l10n = await AppLocalizations.delegate.load(locale);

          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(2));

          final heading = find.byKey(
            const ValueKey('bazarr-home-section-title'),
          );
          final headingNode = tester.getSemantics(heading);
          expect(headingNode.label, 'Bazarr');
          expect(headingNode.flagsCollection.isHeader, isTrue);
          expect(headingNode.flagsCollection.isButton, isFalse);

          final refresh = find.byKey(const ValueKey('bazarr-home-refresh'));
          final refreshNode = tester.getSemantics(refresh);
          expect(refreshNode.label, l10n.commonRefresh);
          expect(refreshNode.flagsCollection.isButton, isTrue);
          expect(refreshNode.rect.width, greaterThanOrEqualTo(48));
          expect(refreshNode.rect.height, greaterThanOrEqualTo(48));

          final search = find.byKey(
            const ValueKey('bazarr-wanted-movie-42-search'),
          );
          final searchNode = tester.getSemantics(search);
          expect(searchNode.label, contains('Arrival'));
          expect(searchNode.label, contains(l10n.commonSearch));
          expect(searchNode.flagsCollection.isButton, isTrue);
          expect(searchNode.rect.width, greaterThanOrEqualTo(48));
          expect(searchNode.rect.height, greaterThanOrEqualTo(48));

          final refreshLabel = find.descendant(
            of: refresh,
            matching: find.text(l10n.commonRefresh),
          );
          Focus.of(tester.element(refreshLabel)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(movieReads, 2);
          expect(episodeReads, 2);

          final searchLabel = find.descendant(
            of: search,
            matching: find.text('Arrival'),
          );
          Focus.of(tester.element(searchLabel)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(requests, hasLength(1));
          expect(requests.single.method, 'PATCH');
          expect(requests.single.body, contains('radarrid=42'));
          expect(requests.single.body, contains('language=en'));
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
