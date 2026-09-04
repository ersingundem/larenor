import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/features/media/hub/domain/media_identity.dart';
import 'package:larenor/features/media/hub/domain/media_title.dart';
import 'package:larenor/features/navigation/search/domain/local_search_index.dart';
import 'package:larenor/features/navigation/search/domain/navigation_target.dart';
import 'package:larenor/features/settings/data/app_service.dart';

void main() {
  test(
    'home pages are searchable without indexing private contents or actions',
    () {
      final index = LocalSearchIndex.build(pages: HomePageTarget.values);
      for (final query in ['BUGÜN', 'alışveriş', 'takvim', 'notifications']) {
        expect(index.search(query).single.target.location, '/today');
      }
      for (final query in ['diafon', 'Netelsan', 'Algan', 'kapı']) {
        expect(index.search(query).single.target.location, '/intercom');
      }
      expect(index.search('private task body'), isEmpty);
    },
  );

  test('Turkish dotted/dotless I and composed/decomposed accents match', () {
    for (final value in ['IŞIK', 'ışık', 'İŞİK', 'is\u0327ik', 'isik']) {
      expect(foldSearchText(value), 'isik');
    }
    expect(foldSearchText('  ÇĞÖŞÜ   Café\tRésumé  '), 'cgosu cafe resume');
    final index = LocalSearchIndex.build(
      entities: [const LocalSearchEntity(entityId: 'light.desk', name: 'IŞIK')],
    );
    expect(index.search('İşık').single.id, 'entity:light.desk');
  });

  test('exact and prefix names rank ahead of contains and room context', () {
    final index = LocalSearchIndex.build(
      rooms: [
        const DashboardRoom(
          id: 'living',
          name: 'Salon',
          entityIds: ['light.unrelated'],
        ),
      ],
      entities: [
        const LocalSearchEntity(
          entityId: 'light.contains',
          name: 'Büyük salon',
        ),
        const LocalSearchEntity(entityId: 'light.prefix', name: 'Salon ışığı'),
        const LocalSearchEntity(entityId: 'light.unrelated', name: 'Avize'),
      ],
    );
    expect(index.search('salon').map((item) => item.id), [
      'room:living',
      'entity:light.prefix',
      'entity:light.contains',
      'entity:light.unrelated',
    ]);
    expect(index.search('  '), isEmpty);
  });

  test('room membership combines with domain aliases and raw identifiers', () {
    final index = LocalSearchIndex.build(
      rooms: [
        const DashboardRoom(
          id: 'living',
          name: 'Salon',
          entityIds: ['light.lamp', 'media_player.panel'],
        ),
      ],
      entities: [
        const LocalSearchEntity(entityId: 'light.lamp', name: 'Lamp'),
        const LocalSearchEntity(entityId: 'media_player.panel', name: 'Panel'),
        const LocalSearchEntity(entityId: 'light.bed', name: 'Lamp'),
      ],
    );
    for (final query in ['salon light', 'SALON IŞIK', 'salon lamp']) {
      expect(index.search(query).single.id, 'entity:light.lamp');
    }
    expect(index.search('salon tv').single.id, 'entity:media_player.panel');
    expect(index.search('salon media_player').single.roomNames, ['Salon']);
  });

  test('5000 entities sort/deduplicate independently of input order', () {
    final entities = List.generate(
      5000,
      (i) => LocalSearchEntity(
        entityId: 'sensor.device_${i.toString().padLeft(4, '0')}',
        name: 'Device ${i % 100}',
      ),
    );
    final index = LocalSearchIndex.build(entities: [...entities, ...entities]);
    final expected = index.search('device').map((item) => item.id).toList();
    expect(index.length, 5000);
    expect(expected.toSet(), hasLength(5000));
    final shuffled = [...entities]..shuffle(Random(42));
    final other = LocalSearchIndex.build(entities: shuffled);
    expect(other.search('device').map((item) => item.id), expected);
    final renamed = LocalSearchIndex.build(
      entities: [
        LocalSearchEntity(entityId: entities.first.entityId, name: 'Renamed'),
      ],
    );
    expect(
      renamed.search('renamed').single.id,
      'entity:${entities.first.entityId}',
    );
    expect(
      renamed.search('renamed').single.target,
      EntityNavigationTarget(entities.first.entityId),
    );
  });

  test(
    'late bridge merges media aliases with stable IDs and a useful snapshot',
    () {
      final titles = [
        const MediaTitle(
          identity: MediaIdentity(kind: MediaKind.movie, imdbId: 'tt42'),
          title: 'Arrival',
          availability: MediaAvailability.inLibrary,
          jellyfinItemId: 'local42',
        ),
        const MediaTitle(
          identity: MediaIdentity(kind: MediaKind.movie, tmdbId: 42),
          title: 'Geliş',
          availability: MediaAvailability.requested,
        ),
        const MediaTitle(
          identity: MediaIdentity(
            kind: MediaKind.movie,
            tmdbId: 42,
            imdbId: 'tt42',
          ),
          title: 'Arrival',
          year: 2016,
          availability: MediaAvailability.notAvailable,
        ),
      ];
      for (final input in [
        titles,
        titles.reversed,
        [titles[1], titles[0], titles[2]],
      ]) {
        final index = LocalSearchIndex.build(media: input);
        expect(index.length, 1);
        final result = index.search('gelis').single;
        expect(result.id, 'media:movie:tmdb:42');
        final target = result.target as MediaNavigationTarget;
        expect(target.identity.imdbId, 'tt42');
        expect(target.jellyfinItemId, 'local42');
        expect(target.snapshot!.isPlayable, isTrue);
        expect(target.snapshot!.year, 2016);
        expect(index.search('arrival').single.id, result.id);
      }
    },
  );

  test('movie/TV IDs stay separate and unresolvable media is omitted', () {
    final index = LocalSearchIndex.build(
      media: [
        for (final kind in MediaKind.values)
          MediaTitle(
            identity: MediaIdentity(kind: kind, tmdbId: 7),
            title: 'Dune',
            availability: MediaAvailability.notAvailable,
          ),
        const MediaTitle(
          identity: MediaIdentity(kind: MediaKind.movie),
          title: 'Unresolvable',
          availability: MediaAvailability.notAvailable,
        ),
        const MediaTitle(
          identity: MediaIdentity(kind: MediaKind.movie),
          title: 'Home movie',
          jellyfinItemId: 'local-only',
          availability: MediaAvailability.inLibrary,
        ),
      ],
    );
    expect(index.length, 3);
    expect(index.search('dune').map((item) => item.id).toSet(), {
      'media:movie:tmdb:7',
      'media:tv:tmdb:7',
    });
    expect(index.search('home').single.id, 'media:movie:jellyfin:local-only');
  });

  test(
    'scenes/scripts only produce detail navigation and service deduplication',
    () {
      final index = LocalSearchIndex.build(
        entities: [
          const LocalSearchEntity(entityId: 'scene.movie', name: 'Cinema'),
          const LocalSearchEntity(entityId: 'script.movie', name: 'Cinema'),
        ],
        services: [AppService.keenetic, AppService.keenetic],
      );
      final results = index.search('cinema');
      expect(results.map((item) => item.kind), [
        LocalSearchKind.scene,
        LocalSearchKind.script,
      ]);
      expect(
        results.every((item) => item.target is EntityNavigationTarget),
        isTrue,
      );
      expect(
        index.search('yönlendirici').single.target,
        const SystemNavigationTarget(AppService.keenetic),
      );
    },
  );

  test('typed URLs encode identifiers and exclude mutable snapshots', () {
    const room = RoomNavigationTarget('Salon / ç ?');
    expect(Uri.parse(room.location).pathSegments, ['rooms', 'Salon / ç ?']);
    expect(
      const EntityNavigationTarget('light.lamp').location,
      '/entities/light.lamp',
    );
    expect(
      const SystemNavigationTarget(AppService.proxmox).location,
      '/system/proxmox',
    );
    const identity = MediaIdentity(
      kind: MediaKind.tv,
      tmdbId: 2,
      imdbId: 'tt12',
    );
    const target = MediaNavigationTarget(
      identity: identity,
      jellyfinItemId: 'a/b?c',
    );
    final withSnapshot = MediaNavigationTarget(
      identity: identity,
      jellyfinItemId: 'a/b?c',
      snapshot: const MediaTitle(
        identity: identity,
        title: 'New name',
        availability: MediaAvailability.inLibrary,
      ),
    );
    expect(target, withSnapshot);
    expect(target.hashCode, withSnapshot.hashCode);
    expect(Uri.parse(target.location).queryParameters, {
      'kind': 'tv',
      'tmdb': '2',
      'imdb': 'tt12',
      'jellyfin': 'a/b?c',
    });
    expect(target.location, isNot(contains('New name')));
  });
}
