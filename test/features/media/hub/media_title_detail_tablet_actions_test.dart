import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/media/arr/providers/radarr_providers.dart';
import 'package:larenor/features/media/arr/providers/sonarr_providers.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/media/hub/presentation/media_title_detail_screen.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/hub/providers/media_details_providers.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_client.dart';
import 'package:larenor/features/media/jellyseerr/data/jellyseerr_config.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_details.dart';
import 'package:larenor/features/media/jellyseerr/data/models/jellyseerr_result.dart';
import 'package:larenor/features/media/jellyseerr/providers/jellyseerr_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _title = MediaTitle(
  identity: MediaIdentity(kind: MediaKind.tv, tmdbId: 2),
  title: 'Family series',
  availability: MediaAvailability.notAvailable,
);

const _details = JellyseerrDetails(
  result: JellyseerrResult(
    id: 2,
    mediaType: 'tv',
    name: 'Family series',
    mediaInfo: JellyseerrMediaInfo(status: 1),
  ),
  seasons: [
    JellyseerrSeasonSummary(seasonNumber: 1, name: 'Season 1', episodeCount: 8),
  ],
);

class _Harness {
  late final JellyseerrClient client;
  late final ProviderContainer container;
  late final GoRouter router;

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(600, 900),
    double scale = 1,
    String language = 'en',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    client = JellyseerrClient(
      config: const JellyseerrConfig(
        baseUrl: 'http://seerr.invalid',
        apiKey: 'test',
      ),
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({'id': 1}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        jellyfinClientProvider.overrideWith((ref) => null),
        jellyseerrClientProvider.overrideWith((ref) => client),
        sonarrClientProvider.overrideWith((ref) => null),
        radarrClientProvider.overrideWith((ref) => null),
        mediaCatalogueDetailsProvider.overrideWith(
          (ref, identity) async => _details,
        ),
        mediaLibraryIndexProvider.overrideWith(
          (ref) async => MediaLibraryIndex.empty,
        ),
        mediaHubRowsProvider.overrideWith((ref) async => []),
        jellyseerrMyRequestsProvider.overrideWith((ref) async => []),
      ],
    );
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const MediaTitleDetailScreen(title: _title),
        ),
        GoRoute(
          path: '/cover',
          builder: (_, _) =>
              const CupertinoPageScaffold(child: Center(child: Text('Cover'))),
        ),
      ],
    );
    addTearDown(() {
      router.dispose();
      container.dispose();
      client.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp.router(
          routerConfig: router,
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final size in [const Size(600, 900), const Size(1200, 900)]) {
      testWidgets(
        '$language media detail request is a 48dp keyboard flow at ${size.width}px and 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await _Harness().mount(
              tester,
              size: size,
              scale: 2,
              language: language,
            );
            final primary = find.byKey(const ValueKey('media-primary-request'));
            expect(tester.getRect(primary).height, greaterThanOrEqualTo(48));
            expect(
              tester.getSemantics(primary).flagsCollection.isButton,
              isTrue,
            );
            Focus.of(
              tester.element(
                find.descendant(of: primary, matching: find.byType(Text)).first,
              ),
            ).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();

            final confirm = find.byKey(const ValueKey('media-confirm-request'));
            final cancel = find.byKey(const ValueKey('media-cancel-request'));
            for (final action in [confirm, cancel]) {
              await tester.ensureVisible(action);
              expect(tester.getRect(action).height, greaterThanOrEqualTo(48));
              expect(
                tester.getSemantics(action).flagsCollection.isButton,
                isTrue,
              );
            }
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets('covered media detail rejects a retained request callback', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    final callback = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('media-primary-request')),
        )
        .onPressed!;
    harness.router.push('/cover');
    await tester.pumpAndSettle();
    callback();
    await tester.pump();
    harness.router.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('media-request-seasons')), findsNothing);
  });
}
