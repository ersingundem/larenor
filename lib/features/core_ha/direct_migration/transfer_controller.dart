import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/configuration_writes.dart';
import '../../../core/direct_home_access.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../auth/data/credentials_store.dart';
import '../../auth/data/ha_connection_config.dart';
import '../../dashboard/data/dashboard_repository.dart';
import '../../dashboard/domain/tile_config.dart';
import '../../home_resources/data/home_resources_api.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../data/core_ha_api.dart';
import '../domain/core_ha_models.dart';
import 'transfer_api.dart';
import 'transfer_models.dart';

class CoreHaTransferController extends ChangeNotifier {
  CoreHaTransferController({
    required this.home,
    required this.repository,
    required this.credentials,
    required this.factory,
    required this.clock,
    required this.monotonic,
    required this.requestId,
    required this.current,
    required this.owner,
  }) : _session = home?.account.session,
       _generation = home?.account.generation,
       _identity = home?.runtimeIdentity,
       _homeEpoch = home?.interaction.epoch {
    home?.addListener(_changed);
    home?.account.addListener(_changed);
    home?.interaction.addListener(_changed);
    owner.addListener(_changed);
    final session = _session;
    if (session != null) {
      final remaining = session.expiresAt
          .subtract(const Duration(seconds: 30))
          .difference(clock());
      _authTimer = Timer(
        remaining.isNegative ? Duration.zero : remaining,
        _changed,
      );
    }
  }
  final HomeSessionController? home;
  final DashboardRepository repository;
  final CredentialsStore credentials;
  final ServerApiFactory factory;
  final DateTime Function() clock;
  final Duration Function() monotonic;
  final String Function() requestId;
  final bool Function() current;
  final Listenable owner;
  List<HomeResourceRecord> items = const [];
  List<String> entities = const [];
  CoreHaTransferPreview? _preview;
  CoreHaTransferPreview? get preview =>
      fresh && _deadline != null && monotonic() < _deadline! ? _preview : null;
  CoreHaTransferReceipt? receipt;
  bool busy = false, uncertain = false;
  String? failure;
  String? nextAfter, _snapshot;
  bool loaded = false;
  int excludedCount = 0, epoch = 0;
  int _loadedRecords = 0;
  final ServerSession? _session;
  final int? _generation, _homeEpoch;
  final Object? _identity;
  bool _retired = false, _disposed = false;
  LarenorServerApi? _transport;
  Timer? _authTimer, _ttlTimer;
  Duration? _deadline;
  DashboardSnapshot? _layout;
  HaConnectionConfig? _capturedCredentials;
  CoreHaTransferPreview? _recoverable;
  HomeResourceRecord? _target;
  String? _entity;
  final _minimum = <String, (int, int)>{};
  bool _safe(bool Function() fn) {
    try {
      return fn();
    } catch (_) {
      return false;
    }
  }

  bool get fresh {
    final account = home?.account, session = _session;
    return !_disposed &&
        !_retired &&
        _safe(current) &&
        home != null &&
        home!.source == HomeSource.directLocal &&
        !home!.busy &&
        home!.failure == null &&
        home!.runtimeIdentity == _identity &&
        home!.interaction.active &&
        home!.interaction.epoch == _homeEpoch &&
        account!.initialized &&
        !account.working &&
        !account.hasPendingContext &&
        account.isCurrent(_generation!) &&
        session != null &&
        identical(account.session, session) &&
        session.context != null &&
        !session.authMutationPending &&
        !session.user.mustChangePassword &&
        session.user.canAdminister &&
        !session.expiresSoon(clock());
  }

  bool get canLoad => fresh && !busy && !uncertain && preview == null;
  bool get canPrepare =>
      fresh &&
      loaded &&
      !busy &&
      !uncertain &&
      preview == null &&
      receipt == null;
  bool get canConfirm => fresh && !busy && !uncertain && preview != null;
  bool get canRecover => fresh && !busy && uncertain && _recoverable != null;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _dropPreview() {
    _preview = null;
    _capturedCredentials = null;
    _deadline = null;
    _ttlTimer?.cancel();
    _ttlTimer = null;
  }

  void _clear() {
    _dropPreview();
    _recoverable = null;
    _target = null;
    _entity = null;
    _layout = null;
    items = const [];
    entities = const [];
    receipt = null;
    loaded = false;
    nextAfter = null;
    _snapshot = null;
    uncertain = false;
    excludedCount = 0;
    _loadedRecords = 0;
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    epoch++;
    busy = false;
    failure = null;
    _clear();
    _transport?.close();
    _transport = null;
    _authTimer?.cancel();
    _authTimer = null;
    _emit();
  }

  void _changed() {
    if (!_disposed && !fresh) _retire();
  }

  void _check() {
    if (!fresh) {
      _retire();
      throw const LarenorServerException('cancelled');
    }
  }

  void _deadlineCheck(Duration deadline) {
    _check();
    if (monotonic() >= deadline) {
      throw const LarenorServerException('ha_migration_preview_invalid');
    }
  }

  List<String> _switches(DashboardSnapshot value) {
    if (value.scope != null) throw const LarenorServerException('cancelled');
    final layout = value.layout;
    return List.unmodifiable(
      {
            ...layout.rooms.expand((room) => room.entityIds),
            ...layout.tiles
                .where((tile) => tile.type == TileType.entity)
                .map((tile) => tile.entityId)
                .whereType<String>(),
            ...layout.favoriteEntityIds,
          }
          .where(
            (entity) =>
                coreHaSwitchEntityId(entity) &&
                !layout.hiddenEntityIds.contains(entity),
          )
          .toList()
        ..sort(),
    );
  }

  Future<void> _run(
    Future<void> Function(
      LarenorServerApi api,
      String token,
      void Function() check,
    )
    operation, {
    bool Function()? guard,
    bool Function()? dispatched,
  }) async {
    if (!fresh || busy || guard != null && !_safe(guard)) return;
    final stamp = ++epoch;
    busy = true;
    failure = null;
    _emit();
    bool valid() => fresh && stamp == epoch && (guard == null || _safe(guard));
    void check() {
      _check();
      if (!valid()) throw const LarenorServerException('cancelled');
    }

    try {
      await home!.account.withSession((_, session) async {
        check();
        if (!identical(session, _session)) {
          throw const LarenorServerException('cancelled');
        }
        final api = factory(session.endpoint);
        _transport = api;
        try {
          await operation(api, session.accessToken, check);
          check();
        } catch (_) {
          check();
          rethrow;
        }
      });
      check();
    } catch (error) {
      if (valid()) {
        failure = switch (error) {
          LarenorServerException e => e.code,
          DirectHomeAccessException e => e.code,
          DashboardStorageException _ => 'ha_migration_changed',
          _ => 'connection_failed',
        };
        final definite = {
          'forbidden',
          'not_found',
          'invalid_request',
          'revision_conflict',
          'ha_migration_changed',
          'ha_migration_preview_invalid',
          'ha_migration_limit_reached',
        };
        uncertain = dispatched?.call() == true && !definite.contains(failure);
        _dropPreview();
        if (!uncertain) _recoverable = null;
        if (failure == 'forbidden' || failure == 'not_found') _clear();
      }
    } finally {
      if (!_disposed && stamp == epoch) {
        _transport?.close();
        _transport = null;
        busy = false;
        if (!valid()) _retire();
        _emit();
      }
    }
  }

  Future<void> load({bool more = false}) async {
    if (!canLoad || more && nextAfter == null) return;
    final after = more ? nextAfter : null, snapshot = more ? _snapshot : null;
    if (!more) {
      _clear();
    }
    await _run((api, token, check) async {
      final local = await repository.readSnapshot();
      check();
      final switches = _switches(local);
      final page = await HomeResourcesApi(
        api,
        token,
        _session!.context!,
      ).list(after: after, snapshot: snapshot);
      check();
      final count = (more ? _loadedRecords : 0) + page.entries.length;
      if (count > HomeResourcePage.maximumRecords) {
        throw const LarenorServerException('invalid_response');
      }
      final all = [
        ...(more ? items : <HomeResourceRecord>[]),
        ...page.entries.where((r) => r.kind == HomeResourceKind.resource),
      ];
      if (all.length > HomeResourcePage.maximumRecords ||
          all.map((r) => r.id).toSet().length != all.length) {
        throw const LarenorServerException('invalid_response');
      }
      for (final item in page.entries) {
        final old = _minimum[item.id];
        if (old == null && _minimum.length >= HomeResourcePage.maximumRecords) {
          throw const LarenorServerException('invalid_response');
        }
        if (old != null &&
            (item.revision < old.$1 || item.aclRevision < old.$2)) {
          throw const LarenorServerException('invalid_response');
        }
        _minimum[item.id] = (item.revision, item.aclRevision);
      }
      _layout = local;
      _loadedRecords = count;
      entities = switches;
      items = List.unmodifiable(all);
      excludedCount =
          local.layout.rooms.length +
          local.layout.tiles
              .where(
                (t) =>
                    t.type != TileType.entity || !switches.contains(t.entityId),
              )
              .length;
      _snapshot = page.snapshot;
      nextAfter = page.nextAfter;
      loaded = true;
    });
    if (failure != null) {
      items = const [];
      entities = const [];
      loaded = false;
      _layout = null;
      nextAfter = null;
      _emit();
    }
  }

  Future<void> prepare(
    HomeResourceRecord target,
    String entity, {
    required bool Function() isCurrent,
  }) async {
    if (!canPrepare ||
        !items.any((r) => identical(r, target)) ||
        !entities.contains(entity) ||
        !_safe(isCurrent)) {
      return;
    }
    final local = _layout!, id = requestId();
    await _run((api, token, check) async {
      bool valid() {
        try {
          check();
          return true;
        } catch (_) {
          return false;
        }
      }

      final currentApi = CoreHaApi(api, token, target, isCurrent: valid);
      final record = await currentApi.resource();
      check();
      if (record.revision != target.revision ||
          record.aclRevision != target.aclRevision) {
        throw const LarenorServerException('ha_migration_changed');
      }
      if (await currentApi.binding() != null) {
        throw const LarenorServerException('ha_migration_changed');
      }
      check();
      await ConfigurationWrites.run(() async {
        check();
        final before = await repository.readSnapshot();
        check();
        if (before.fingerprint != local.fingerprint ||
            !_switches(before).contains(entity)) {
          throw const LarenorServerException('ha_migration_changed');
        }
        final config = await credentials.readForTransfer(isCurrent: valid);
        check();
        if (config == null) {
          throw const DirectHomeAccessException('invalid_record');
        }
        final started = monotonic();
        final preview =
            await CoreHaTransferApi(
              api,
              token,
              record,
              isCurrent: valid,
            ).preview(
              requestId: id,
              name: 'Home Assistant',
              baseUrl: config.baseUrl,
              credential: config.token,
              entityId: entity,
            );
        check();
        final deadline = started + Duration(milliseconds: preview.expiresInMs);
        _deadlineCheck(deadline);
        _target = record;
        _entity = entity;
        _capturedCredentials = config;
        _preview = preview;
        _deadline = deadline;
        _ttlTimer?.cancel();
        _ttlTimer = Timer(deadline - monotonic(), () {
          if (_disposed || !identical(_preview, preview)) return;
          _dropPreview();
          failure = 'ha_migration_preview_invalid';
          _emit();
        });
      });
    }, guard: isCurrent);
  }

  Future<void> confirm(
    CoreHaTransferPreview value, {
    required bool Function() isCurrent,
  }) async {
    if (!canConfirm || !identical(value, preview) || !_safe(isCurrent)) return;
    final deadline = _deadline!,
        original = _capturedCredentials!,
        local = _layout!,
        target = _target!,
        entity = _entity!;
    var dispatched = false;
    _dropPreview();
    _recoverable = value;
    await _run(
      (api, token, check) => ConfigurationWrites.run(() async {
        void live() {
          check();
          _deadlineCheck(deadline);
        }

        bool valid() {
          try {
            check();
            return true;
          } catch (_) {
            return false;
          }
        }

        live();
        final before = await repository.readSnapshot();
        live();
        if (before.fingerprint != local.fingerprint ||
            !_switches(before).contains(entity)) {
          throw const LarenorServerException('ha_migration_changed');
        }
        final config = await credentials.readForTransfer(
          isCurrent: () => valid() && monotonic() < deadline,
        );
        live();
        if (config == null ||
            config.baseUrl != original.baseUrl ||
            config.token != original.token) {
          throw const LarenorServerException('ha_migration_changed');
        }
        dispatched = true;
        final result =
            await CoreHaTransferApi(
              api,
              token,
              target,
              isCurrent: valid,
            ).confirm(
              value,
              name: 'Home Assistant',
              baseUrl: config.baseUrl,
              credential: config.token,
              entityId: entity,
            );
        check();
        receipt = result;
        uncertain = false;
        _recoverable = null;
      }),
      guard: isCurrent,
      dispatched: () => dispatched,
    );
  }

  Future<void> cancel(
    CoreHaTransferPreview value, {
    required bool Function() isCurrent,
  }) async {
    if (!canConfirm || !identical(value, preview) || !_safe(isCurrent)) return;
    final target = _target!;
    _dropPreview();
    await _run((api, token, check) async {
      bool valid() {
        try {
          check();
          return true;
        } catch (_) {
          return false;
        }
      }

      await CoreHaTransferApi(
        api,
        token,
        target,
        isCurrent: valid,
      ).cancel(value);
      check();
    }, guard: isCurrent);
  }

  Future<void> recover({required bool Function() isCurrent}) async {
    if (!canRecover || !_safe(isCurrent)) return;
    final value = _recoverable!, target = _target!;
    await _run(
      (api, token, check) async {
        bool valid() {
          try {
            check();
            return true;
          } catch (_) {
            return false;
          }
        }

        final result = await CoreHaTransferApi(
          api,
          token,
          target,
          isCurrent: valid,
        ).result(value);
        check();
        if (result == null) {
          failure = 'not_found';
          return;
        }
        receipt = result;
        uncertain = false;
        _recoverable = null;
      },
      guard: isCurrent,
      dispatched: () => true,
    );
  }

  @override
  void dispose() {
    home?.removeListener(_changed);
    home?.account.removeListener(_changed);
    home?.interaction.removeListener(_changed);
    owner.removeListener(_changed);
    _retire();
    _disposed = true;
    super.dispose();
  }
}
