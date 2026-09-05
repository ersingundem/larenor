import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/dashboard/providers/dashboard_providers.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/features/media/hub/domain/media_library_index.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/media/hub/providers/media_catalog_providers.dart';
import 'package:larenor/features/media/jellyfin/data/models/jellyfin_item.dart';
import 'package:larenor/features/navigation/search/domain/local_search_index.dart';
import 'package:larenor/features/navigation/search/domain/navigation_target.dart';
import 'package:larenor/features/navigation/search/providers/local_search_providers.dart';
import 'package:larenor/features/settings/data/app_service.dart';
import 'package:larenor/features/settings/providers/enabled_services_providers.dart';

class _Entities extends Entities {
  _Entities(this.initial);
  final Map<String, HaEntity> initial;
  @override
  Future<Map<String, HaEntity>> build() async => initial;
  void publish(Map<String, HaEntity> value) => state = AsyncData(value);
}

class _Enabled extends EnabledServices {
  @override
  Future<Set<AppService>> build() async => {AppService.keenetic};
  void publish(Set<AppService> value) => state = AsyncData(value);
}

final _accountProvider = NotifierProvider<_Account, int>(_Account.new);

class _Account extends Notifier<int> {
  @override
  int build() => 0;
  void change() => state++;
}

class _AccountEntities extends Entities {
  _AccountEntities(this.next);
  final Completer<Map<String, HaEntity>> next;
  @override
  Future<Map<String, HaEntity>> build() async =>
      ref.watch(_accountProvider) == 0
      ? {
          'light.old': const HaEntity(
            entityId: 'light.old',
            state: 'on',
            attributes: {'friendly_name': 'Old private lamp'},
          ),
        }
      : next.future;
}

void main() {
  test('account reload hides old media and HA caches until the new snapshot resolves', () async {
    final nextEntities = Completer<Map<String, HaEntity>>();
    final nextLibrary = Completer<MediaLibraryIndex>();
    final nextRows = Completer<List<MediaRowData>>();
    final container = ProviderContainer(
      overrides: [
        entitiesProvider.overrideWith(() => _AccountEntities(nextEntities)),
        mediaLibraryIndexProvider.overrideWith((ref) async {
          if (ref.watch(_accountProvider) == 0) {
            return MediaLibraryIndex.build(
              jellyfinItems: [
                const JellyfinItem(
                  id: 'old-local',
                  name: 'Old private movie',
                  type: 'Movie',
                ),
              ],
            );
          }
          return nextLibrary.future;
        }),
        mediaHubRowsProvider.overrideWith((ref) async {
          if (ref.watch(_accountProvider) == 0) {
            return const [
              MediaRowData(
                id: MediaRowId.trending,
                titles: [
                  MediaTitle(
                    identity: MediaIdentity(kind: MediaKind.movie, tmdbId: 2),
                    title: 'Old private catalog',
                    availability: MediaAvailability.notAvailable,
                  ),
                ],
              ),
            ];
          }
          return nextRows.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(entitiesProvider, (_, _) {});
    container.listen(mediaLibraryIndexProvider, (_, _) {});
    container.listen(mediaHubRowsProvider, (_, _) {});
    await container.read(entitiesProvider.future);
    await container.read(mediaLibraryIndexProvider.future);
    await container.read(mediaHubRowsProvider.future);
    container.listen(localSearchIndexProvider, (_, _) {});
    expect(
      container.read(localSearchIndexProvider).search('private'),
      hasLength(3),
    );
    final movieHit = container
        .read(localSearchIndexProvider)
        .search('private movie')
        .singleWhere((hit) => hit.id == 'media:movie:jellyfin:old-local');
    final movieTarget = movieHit.target as MediaNavigationTarget;
    expect(movieHit.id, 'media:movie:jellyfin:old-local');
    expect(movieTarget.uri.queryParameters['jellyfin'], 'old-local');
    expect(movieTarget.snapshot!.jellyfinLookupId, 'old-local');
    expect(movieTarget.snapshot!.jellyfinItemId, isNull);
    expect(movieTarget.snapshot!.isPlayable, isFalse);
    container.read(_accountProvider.notifier).change();
    await container.pump();
    expect(container.read(entitiesProvider).isReloading, isTrue);
    expect(container.read(mediaLibraryIndexProvider).isReloading, isTrue);
    expect(container.read(mediaHubRowsProvider).isReloading, isTrue);
    expect(container.read(localSearchIndexProvider).search('private'), isEmpty);
    nextEntities.complete({
      'light.new': const HaEntity(
        entityId: 'light.new',
        state: 'off',
        attributes: {'friendly_name': 'New lamp'},
      ),
    });
    nextLibrary.complete(MediaLibraryIndex.empty);
    nextRows.complete([]);
    await container.read(entitiesProvider.future);
    await container.read(mediaLibraryIndexProvider.future);
    await container.read(mediaHubRowsProvider.future);
    expect(container.read(localSearchIndexProvider).search('private'), isEmpty);
    expect(
      container.read(localSearchIndexProvider).search('new lamp').single.id,
      'entity:light.new',
    );
  });

  test('opening and querying cold caches never initializes connections or catalogs', () {
    var coldReads = 0;
    final container = ProviderContainer(
      overrides: [
        entitiesProvider.overrideWithBuild((ref, notifier) async {
          coldReads++;
          return {};
        }),
        dashboardLayoutProvider.overrideWithBuild((ref, notifier) async {
          coldReads++;
          return const DashboardLayout();
        }),
        enabledServicesProvider.overrideWithBuild((ref, notifier) async {
          coldReads++;
          return {};
        }),
        mediaLibraryIndexProvider.overrideWith((ref) async {
          coldReads++;
          return MediaLibraryIndex.empty;
        }),
        mediaHubRowsProvider.overrideWith((ref) async {
          coldReads++;
          return [];
        }),
        keeneticConnectionProvider.overrideWithBuild((ref, notifier) async {
          coldReads++;
          return null;
        }),
        keeneticClientProvider.overrideWith((ref) async {
          coldReads++;
          throw StateError('Search may never log in');
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(localSearchIndexProvider, (_, _) {});
    for (final query in ['', 'salon', 'film', 'keenetic']) {
      container.read(localSearchIndexProvider.notifier).refreshCachedSources();
      expect(container.read(localSearchResultsProvider(query)), isEmpty);
    }
    expect(
      container
          .read(localSearchResultsProvider('Bugün'))
          .single
          .target
          .location,
      '/today',
    );
    expect(
      container
          .read(localSearchResultsProvider('Algan'))
          .single
          .target
          .location,
      '/intercom',
    );
    expect(coldReads, 0);
    expect(container.exists(entitiesProvider), isFalse);
    expect(container.exists(mediaLibraryIndexProvider), isFalse);
    expect(container.exists(keeneticConnectionProvider), isFalse);
    expect(container.exists(keeneticClientProvider), isFalse);
  });

  test(
    '5000 cached entities reuse the index for state-only updates and queries',
    () async {
      final initial = {
        for (var i = 0; i < 5000; i++)
          'light.lamp_$i': HaEntity(
            entityId: 'light.lamp_$i',
            state: 'off',
            attributes: {'friendly_name': 'Lamp $i'},
          ),
      };
      final entities = _Entities(initial);
      final container = ProviderContainer(
        overrides: [
          entitiesProvider.overrideWith(() => entities),
          dashboardLayoutProvider.overrideWithBuild(
            (ref, notifier) async => const DashboardLayout(
              rooms: [
                DashboardRoom(
                  id: 'living',
                  name: 'Salon',
                  entityIds: ['light.lamp_0'],
                ),
              ],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(entitiesProvider, (_, _) {});
      container.listen(dashboardLayoutProvider, (_, _) {});
      await container.read(entitiesProvider.future);
      await container.read(dashboardLayoutProvider.future);
      container.listen(localSearchIndexProvider, (_, _) {});
      final index = container.read(localSearchIndexProvider);
      expect(index.length, 5007);
      expect(index.search('salon light').single.id, 'entity:light.lamp_0');
      final changed = {
        for (final entry in initial.entries)
          entry.key: entry.value.copyWith(state: 'on'),
      };
      entities.publish(changed);
      expect(
        identical(container.read(localSearchIndexProvider), index),
        isTrue,
      );
      for (final query in ['lamp', 'lamp 3', 'salon', 'salon light']) {
        container
            .read(localSearchIndexProvider.notifier)
            .refreshCachedSources();
        expect(container.read(localSearchResultsProvider(query)), isNotEmpty);
        expect(
          identical(container.read(localSearchIndexProvider), index),
          isTrue,
        );
      }
      entities.publish({
        ...changed,
        'light.lamp_0': changed['light.lamp_0']!.copyWith(
          attributes: {'friendly_name': 'Avize'},
        ),
      });
      final renamed = container.read(localSearchIndexProvider);
      expect(identical(renamed, index), isFalse);
      expect(renamed.search('avize').single.id, 'entity:light.lamp_0');
    },
  );

  test(
    'newly loaded media is discovered on refresh without another fetch',
    () async {
      var reads = 0;
      final container = ProviderContainer(
        overrides: [
          mediaLibraryIndexProvider.overrideWith((ref) async {
            reads++;
            return MediaLibraryIndex.build(
              jellyfinItems: [
                const JellyfinItem(
                  id: 'movie',
                  name: 'Arrival',
                  type: 'Movie',
                  providerIds: {'Tmdb': '42'},
                ),
              ],
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      container.listen(localSearchIndexProvider, (_, _) {});
      expect(
        container.read(localSearchIndexProvider).search('arrival'),
        isEmpty,
      );
      container.listen(mediaLibraryIndexProvider, (_, _) {});
      await container.read(mediaLibraryIndexProvider.future);
      container.read(localSearchIndexProvider.notifier).refreshCachedSources();
      for (final query in ['arrival', 'film', 'movie']) {
        expect(
          container.read(localSearchResultsProvider(query)).single.kind,
          LocalSearchKind.media,
        );
      }
      expect(reads, 1);
    },
  );

  test(
    'only enabled configured cached systems are exposed without credentials',
    () async {
      final enabled = _Enabled();
      var connectionReads = 0;
      final container = ProviderContainer(
        overrides: [
          enabledServicesProvider.overrideWith(() => enabled),
          keeneticConnectionProvider.overrideWithBuild((ref, notifier) async {
            connectionReads++;
            return const KeeneticConfig(
              baseUrl: 'https://router.private',
              username: 'private-user',
              password: 'private-password',
            );
          }),
          keeneticClientProvider.overrideWith(
            (ref) async => throw StateError('no login'),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(enabledServicesProvider, (_, _) {});
      container.listen(keeneticConnectionProvider, (_, _) {});
      await container.read(enabledServicesProvider.future);
      await container.read(keeneticConnectionProvider.future);
      container.listen(localSearchIndexProvider, (_, _) {});
      var index = container.read(localSearchIndexProvider);
      expect(
        index.search('keenetic').single.target.location,
        '/system/keenetic',
      );
      expect(index.search('private'), isEmpty);
      expect(connectionReads, 1);
      expect(container.exists(keeneticClientProvider), isFalse);
      enabled.publish({});
      index = container.read(localSearchIndexProvider);
      expect(index.search('keenetic'), isEmpty);
    },
  );
}
