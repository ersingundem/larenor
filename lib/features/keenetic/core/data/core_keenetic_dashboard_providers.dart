import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/home_session_controller.dart';
import '../../../../core/home_source_store.dart';
import '../../../dashboard/domain/tile_config.dart';
import '../../../home_resources/data/home_resources_api.dart';
import '../../../home_resources/domain/home_resource_models.dart';
import '../../../server/domain/server_models.dart';
import '../domain/core_keenetic_models.dart';
import 'core_keenetic_api.dart';
import 'core_keenetic_providers.dart';

typedef _Authority = ({
  HomeSessionController home,
  ServerSession session,
  Object identity,
  int generation,
  int interactionEpoch,
  DateTime Function() clock,
});

_Authority _authority(Ref ref) {
  final home = ref.watch(homeSessionControllerProvider);
  if (home == null) throw const LarenorServerException('core_required');
  void changed() => ref.invalidateSelf();
  home.addListener(changed);
  ref.onDispose(() => home.removeListener(changed));
  final account = home.account, session = account.session;
  final clock = ref.watch(coreKeeneticClockProvider);
  if (home.source != HomeSource.verifiedCore ||
      home.busy ||
      home.failure != null ||
      !home.interaction.active ||
      !account.initialized ||
      account.working ||
      account.hasPendingContext ||
      session == null ||
      session.context == null ||
      session.authMutationPending ||
      session.user.mustChangePassword ||
      session.expiresSoon(clock())) {
    throw const LarenorServerException('core_required');
  }
  return (
    home: home,
    session: session,
    identity: home.runtimeIdentity,
    generation: account.generation,
    interactionEpoch: home.interaction.epoch,
    clock: clock,
  );
}

bool _current(Ref ref, _Authority value) {
  try {
    final home = value.home;
    return ref.mounted &&
        identical(ref.read(homeSessionControllerProvider), home) &&
        home.runtimeIdentity == value.identity &&
        home.source == HomeSource.verifiedCore &&
        !home.busy &&
        home.failure == null &&
        home.interaction.active &&
        home.interaction.epoch == value.interactionEpoch &&
        home.account.isCurrent(value.generation) &&
        identical(home.account.session, value.session) &&
        !value.session.expiresSoon(value.clock());
  } catch (_) {
    return false;
  }
}

HomeResourceRecord coreKeeneticTileTarget(
  TileConfig tile,
  ServerContext context,
) {
  if (tile.type != TileType.coreKeenetic ||
      tile.coreId != context.coreId ||
      tile.coreHomeId != context.homeId) {
    throw const LarenorServerException('resource_changed');
  }
  return HomeResourceRecord.fromJson({
    'ref': {
      'schemaVersion': 1,
      'coreId': tile.coreId,
      'homeId': tile.coreHomeId,
      'kind': 'resource',
      'id': tile.coreResourceId,
    },
    'label': tile.title?.trim().isNotEmpty == true
        ? tile.title!.trim()
        : 'Keenetic',
    'order': 0,
    'revision': tile.coreResourceRevision,
    'aclRevision': tile.coreResourceAclRevision,
    'permissions': {'read': true, 'write': false},
  }, expectedContext: context);
}

void validateCoreKeeneticDashboardReadback(
  TileConfig tile,
  HomeResourceRecord record,
  CoreKeeneticSnapshot snapshot,
) {
  if (record.context.coreId != tile.coreId ||
      record.context.homeId != tile.coreHomeId ||
      record.id != tile.coreResourceId ||
      record.kind != HomeResourceKind.resource ||
      record.revision != tile.coreResourceRevision ||
      record.aclRevision != tile.coreResourceAclRevision ||
      snapshot.bindingId != tile.coreBindingId ||
      snapshot.bindingRevision != tile.coreBindingRevision ||
      snapshot.resourceRevision != tile.coreResourceRevision ||
      snapshot.aclRevision != tile.coreResourceAclRevision) {
    throw const LarenorServerException('resource_changed');
  }
}

final coreKeeneticDashboardResourcesProvider = FutureProvider.autoDispose((
  ref,
) async {
  final authority = _authority(ref), session = authority.session;
  final transport = ref.watch(coreKeeneticApiFactoryProvider)(session.endpoint);
  var closed = false;
  void close() {
    if (!closed) {
      closed = true;
      transport.close();
    }
  }

  ref.onDispose(close);
  final api = HomeResourcesApi(
    transport,
    session.accessToken,
    session.context!,
  );
  final values = <HomeResourceRecord>[];
  String? after, snapshot;
  try {
    do {
      if (!_current(ref, authority)) {
        throw const LarenorServerException('cancelled');
      }
      final page = await api.list(after: after, snapshot: snapshot, limit: 100);
      if (!_current(ref, authority)) {
        throw const LarenorServerException('cancelled');
      }
      snapshot ??= page.snapshot;
      values.addAll(
        page.entries.where((entry) => entry.kind == HomeResourceKind.resource),
      );
      if (values.length > HomeResourcePage.maximumRecords) {
        throw const LarenorServerException('invalid_response');
      }
      after = page.nextAfter;
    } while (after != null);
    return List<HomeResourceRecord>.unmodifiable(values);
  } finally {
    close();
  }
}, retry: (_, _) => null);

final coreKeeneticDashboardSnapshotProvider = FutureProvider.autoDispose
    .family<CoreKeeneticSnapshot, TileConfig>((ref, tile) async {
      final authority = _authority(ref), session = authority.session;
      final transport = ref.watch(coreKeeneticApiFactoryProvider)(
        session.endpoint,
      );
      var live = true, closed = false;
      void close() {
        live = false;
        if (!closed) {
          closed = true;
          transport.close();
        }
      }

      ref.onDispose(close);
      bool current() => live && _current(ref, authority);
      try {
        final target = coreKeeneticTileTarget(tile, session.context!);
        final api = CoreKeeneticApi(
          transport,
          session.accessToken,
          target,
          isCurrent: current,
        );
        final record = await api.resource();
        if (record.revision != tile.coreResourceRevision ||
            record.aclRevision != tile.coreResourceAclRevision) {
          throw const LarenorServerException('resource_changed');
        }
        final value = await CoreKeeneticApi(
          transport,
          session.accessToken,
          record,
          isCurrent: current,
        ).snapshot();
        validateCoreKeeneticDashboardReadback(tile, record, value);
        return value;
      } finally {
        close();
      }
    }, retry: (_, _) => null);

final coreKeeneticDashboardDraftProvider = FutureProvider.autoDispose
    .family<TileConfig, HomeResourceRecord>((ref, target) async {
      final authority = _authority(ref), session = authority.session;
      if (target.context != session.context ||
          target.kind != HomeResourceKind.resource) {
        throw const LarenorServerException('resource_changed');
      }
      final transport = ref.watch(coreKeeneticApiFactoryProvider)(
        session.endpoint,
      );
      var live = true, closed = false;
      void close() {
        live = false;
        if (!closed) {
          closed = true;
          transport.close();
        }
      }

      ref.onDispose(close);
      bool current() => live && _current(ref, authority);
      try {
        final api = CoreKeeneticApi(
          transport,
          session.accessToken,
          target,
          isCurrent: current,
        );
        final record = await api.resource();
        if (record.revision != target.revision ||
            record.aclRevision != target.aclRevision) {
          throw const LarenorServerException('resource_changed');
        }
        final snapshot = await CoreKeeneticApi(
          transport,
          session.accessToken,
          record,
          isCurrent: current,
        ).snapshot();
        if (snapshot.resourceRevision != record.revision ||
            snapshot.aclRevision != record.aclRevision) {
          throw const LarenorServerException('resource_changed');
        }
        return TileConfig(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          type: TileType.coreKeenetic,
          x: 0,
          y: 0,
          width: 3,
          height: 2,
          title: record.label,
          coreId: record.context.coreId,
          coreHomeId: record.context.homeId,
          coreResourceId: record.id,
          coreResourceRevision: record.revision,
          coreResourceAclRevision: record.aclRevision,
          coreBindingId: snapshot.bindingId,
          coreBindingRevision: snapshot.bindingRevision,
        );
      } finally {
        close();
      }
    }, retry: (_, _) => null);
