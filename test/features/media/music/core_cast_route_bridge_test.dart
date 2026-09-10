import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/music/core/data/core_cast_route_bridge.dart';
import 'package:larenor/features/media/music/core/data/core_cast_route_coordinator.dart';
import 'package:larenor/features/media/music/core/data/core_music_targets_api.dart';
import 'package:larenor/features/media/music/core/data/core_music_targets_controller.dart';
import 'package:larenor/features/media/music/core/domain/core_music_target_models.dart';

import 'core_music_targets_test.dart' show discoveryFixture;

const castId = '01234567-89ab-cdef-0123-456789abcdef';

void main() {
  test('strict native snapshot rejects secrets, duplicates and stale revision', () {
    final valid = {
      'revision': 8,
      'routes': [routeFixture()],
    };
    final snapshot = CoreCastRouteSnapshot.fromChannel(valid);
    expect(snapshot.routes.single.id, castId);
    expect(snapshot.toString(), isNot(contains('Living TV')));
    for (final invalid in [
      {...valid, 'token': 'private'},
      {
        ...valid,
        'routes': [routeFixture(), routeFixture()],
      },
      {
        ...valid,
        'routes': [routeFixture()..['host'] = '192.168.1.20'],
      },
    ]) {
      expect(
        () => CoreCastRouteSnapshot.fromChannel(invalid),
        throwsA(isA<CoreCastRouteException>()),
      );
    }
  });

  test('only an exact available Chromecast Core target can be selected', () async {
    final lifecycle = ValueNotifier(0);
    final targets = _Targets();
    final core = CoreMusicTargetsController(
      api: targets,
      lifecycle: lifecycle,
      authorized: () => true,
    );
    core.setVisible(true);
    await Future<void>.delayed(Duration.zero);
    final platform = _Platform();
    final routes = CoreCastRouteCoordinator(core: core, platform: platform);
    await routes.start();
    platform.events.add(
      CoreCastRouteSnapshot.fromChannel({
        'revision': 8,
        'routes': [routeFixture()],
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(routes.routes.single.coreTargetId, castId);
    expect(routes.select(castId), isTrue);
    expect(core.selectedTargetId, castId);
    expect(routes.select('homepod-living'), isFalse);

    platform.events.add(
      CoreCastRouteSnapshot.fromChannel({
        'revision': 9,
        'routes': <Object?>[],
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(routes.failure, 'route_lost');
    expect(routes.select(castId), isFalse);

    await routes.dispose();
    unawaited(platform.events.close());
    core.dispose();
    lifecycle.dispose();
  });
}

Map<String, Object?> routeFixture() => {
  'id': castId,
  'name': 'Living TV',
  'kind': 'device',
  'available': true,
  'connectionState': 'disconnected',
  'volumeLevel': null,
};

class _Platform implements CoreCastRoutePlatform {
  final events = StreamController<CoreCastRouteSnapshot>();

  @override
  Stream<CoreCastRouteSnapshot> get snapshots => events.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _Targets implements CoreMusicTargetsApi {
  @override
  Future<CoreMusicTargetInventory> read({
    required bool Function() isCurrent,
  }) async {
    final inventory = jsonDecode(
      jsonEncode(discoveryFixture()['inventory']),
    ) as Map<String, dynamic>;
    final targets = inventory['targets'] as List<dynamic>;
    final cast = Map<String, dynamic>.from(targets.single as Map);
    cast.addAll({
      'id': castId,
      'name': 'Living TV',
      'provider': 'chromecast--fixture',
      'providerDomain': 'chromecast',
      'providerInstanceId': 'chromecast--fixture',
      'transport': 'chromecast',
      'homePod': false,
      'queueId': castId,
    });
    (cast['queue'] as Map<String, dynamic>)['id'] = castId;
    targets.add(cast);
    return CoreMusicTargetInventory.fromJson(inventory);
  }
}
