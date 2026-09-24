import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/dashboard/presentation/tiles/jellyfin_tile.dart';
import 'package:larenor/features/dashboard/presentation/tiles/dashboard_tile_button.dart';
import 'package:larenor/features/media/hub/presentation/media_hub_screen.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../server/server_admin_test_support.dart';

const _installationId = '11111111111111111111111111111111';

final class _CoreSource implements HomeSourcePersistence {
  @override
  Future<HomeSource> read() async => HomeSource.verifiedCore;

  @override
  Future<void> write(HomeSource source) async {}
}

const _tile = TileConfig(
  id: 'jellyfin',
  type: TileType.jellyfin,
  x: 0,
  y: 0,
  width: 2,
  height: 1,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'verified Core tile reads account rows without mounting direct Jellyfin',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final fixture = AdminFixture();
      var resumeTitle = 'Interstellar';
      var rowsFail = false;
      fixture.respond = (request) async {
        if (request.method == 'GET' &&
            request.url.path.endsWith('/media/catalog/target')) {
          return fixture.json({
            'schemaVersion': 1,
            'installationId': _installationId,
            'installationRevision': 7,
            'snapshotRevision': 8,
            'jellyfinServiceRevision': 9,
          });
        }
        if (request.url.path.endsWith('/media/rows/target')) {
          return fixture.json({
            'schemaVersion': 1,
            'installationId': _installationId,
            'installationRevision': 7,
            'bindingRevision': 4,
          });
        }
        if (request.url.path.endsWith('/media/rows/read')) {
          if (rowsFail) {
            return fixture.json({
              'error': {'code': 'media_rows_authority_changed'},
            }, 409);
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['installationId'], _installationId);
          expect(body['expectedInstallationRevision'], 7);
          expect(body['expectedBindingRevision'], 4);
          return fixture.json({
            'requestId': body['requestId'],
            'installationId': _installationId,
            'installationRevision': 7,
            'bindingRevision': 4,
            'rows': {
              'schemaVersion': 1,
              'revision': 10,
              'recent': const [],
              'resume': [
                {
                  'itemId': '22222222222222222222222222222222',
                  'title': resumeTitle,
                  'mediaKind': 'movie',
                  'addedAt': 2000000000,
                  'runtimeSeconds': 10140,
                  'positionSeconds': 1800,
                },
              ],
            },
          });
        }
        return fixture.defaultResponse(request);
      };
      await fixture.account.initialize();
      final home = HomeSessionController(
        store: _CoreSource(),
        account: fixture.account,
      );
      await home.initialize();
      home.runtimeMounted(home.runtimeIdentity);
      final container = ProviderContainer(
        overrides: [
          homeSessionControllerProvider.overrideWithValue(home),
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        home.dispose();
        fixture.account.dispose();
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Center(child: JellyfinTile(tile: _tile)),
          ),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(
        fixture.calls.where((request) => request.url.path.contains('/media/')),
        isEmpty,
      );
      expect(find.text('Interstellar'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Interstellar'), findsOneWidget);
      expect(container.exists(jellyfinConnectionProvider), isFalse);
      expect(container.exists(jellyfinResumeItemsProvider), isFalse);
      expect(
        fixture.calls.map((request) => request.url.path),
        containsAllInOrder([
          '/prefix/api/v1/media/catalog/target',
          '/prefix/api/v1/media/rows/read',
        ]),
      );

      tester
          .widget<DashboardTileButton>(find.byType(DashboardTileButton))
          .onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MediaHubScreen), findsOneWidget);
      resumeTitle = 'Arrival';
      Navigator.of(tester.element(find.byType(MediaHubScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Arrival'), findsOneWidget);
      expect(find.text('Interstellar'), findsNothing);
      rowsFail = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Error'), findsOneWidget);
      expect(find.text('Arrival'), findsNothing);
      expect(container.exists(jellyfinConnectionProvider), isFalse);
      expect(container.exists(jellyfinResumeItemsProvider), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
