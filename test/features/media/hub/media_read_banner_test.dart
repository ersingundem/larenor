import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/health/data/integration_health.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/domain/media_read_result.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/media/hub/presentation/media_hub_screen.dart';
import 'package:larenor/features/media/hub/presentation/media_search_screen.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const _film = MediaTitle(
  identity: MediaIdentity(kind: MediaKind.movie, tmdbId: 42),
  title: 'Available movie',
  availability: MediaAvailability.inLibrary,
);
const _denied = MediaReadIssue(
  MediaReadKey(IntegrationId.jellyseerr, MediaReadOperation.trending),
  HealthFailure.permission,
);
const _auth = MediaReadIssue(
  MediaReadKey(IntegrationId.jellyfin, MediaReadOperation.library),
  HealthFailure.authentication,
);

final _accountProvider = NotifierProvider<_Account, int>(_Account.new);

class _Account extends Notifier<int> {
  @override
  int build() => 0;
  void change() => state++;
}

Widget _app(
  Widget child, {
  double scale = 1,
  Locale locale = const Locale('en'),
}) => CupertinoApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);

Widget _hub(
  Future<List<MediaRowData>> Function(Ref) load, {
  double scale = 1,
  Locale locale = const Locale('en'),
}) => ProviderScope(
  overrides: [
    jellyfinClientProvider.overrideWith((_) => null),
    mediaHubRowsProvider.overrideWith(load),
  ],
  child: _app(const MediaHubScreen(), scale: scale, locale: locale),
);

void main() {
  testWidgets('partial outage keeps content and explains the denied service', (
    tester,
  ) async {
    await tester.pumpWidget(
      _hub(
        (_) async => MediaReadList(
          [
            const MediaRowData(id: MediaRowId.recentlyAdded, titles: [_film]),
          ],
          issues: [_denied],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Some media sources could not be read'), findsOneWidget);
    expect(find.text('Jellyseerr · Permission required'), findsOneWidget);
    expect(find.text('Available movie'), findsWidgets);
    expect(find.text('No media services connected'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed empty snapshot does not claim an empty library; retry recovers',
    (tester) async {
      var reads = 0;
      await tester.pumpWidget(
        _hub((_) async {
          reads++;
          return reads == 1
              ? MediaReadList([], issues: [_auth])
              : MediaReadList(
                  [],
                  successfulReads: [
                    const MediaReadKey(
                      IntegrationId.jellyfin,
                      MediaReadOperation.library,
                    ),
                  ],
                );
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Media could not be verified'), findsOneWidget);
      expect(find.text('Jellyfin · Sign-in required'), findsOneWidget);
      expect(find.text('Your next watch starts here'), findsNothing);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text('Media could not be verified'), findsNothing);
      expect(find.text('Your next watch starts here'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account dependency reload hides old content before new data arrives',
    (tester) async {
      final next = Completer<List<MediaRowData>>();
      await tester.pumpWidget(
        _hub((ref) async {
          if (ref.watch(_accountProvider) == 0) {
            return MediaReadList([
              const MediaRowData(id: MediaRowId.recentlyAdded, titles: [_film]),
            ]);
          }
          return next.future;
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Available movie'), findsWidgets);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MediaHubScreen)),
      );
      container.read(_accountProvider.notifier).change();
      await tester.pump();
      expect(find.text('Available movie'), findsNothing);
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      next.complete(
        MediaReadList(
          [],
          successfulReads: [
            const MediaReadKey(
              IntegrationId.jellyfin,
              MediaReadOperation.library,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Available movie'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone large-text partial banner stays scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _hub(
          (_) async => MediaReadList([], issues: [_auth, _denied]),
          scale: 2,
          locale: const Locale('tr'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Medya doğrulanamadı'), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'remote search shows partial-read evidence rather than nothing found',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaLibraryIndexProvider.overrideWith(
              (_) async => MediaLibraryIndex.empty,
            ),
            mediaSearchProvider.overrideWith(
              (ref, query) async => MediaReadList([], issues: [_denied]),
            ),
          ],
          child: _app(const MediaSearchScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoSearchTextField), 'movie');
      await tester.pump(const Duration(milliseconds: 351));
      await tester.pumpAndSettle();
      expect(find.text('Media could not be verified'), findsOneWidget);
      expect(find.text('Jellyseerr · Permission required'), findsOneWidget);
      expect(find.text('Nothing found'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
