import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/server_models.dart';
import '../domain/server_tablet_fleet_models.dart';
import 'tablet_fleet_device_store.dart';

abstract interface class TabletFleetDeviceClient {
  Future<ManagedTablet> register({
    required String registrationId,
    required String name,
    required String clientVersion,
    required TabletManagementMode mode,
    required int appliedProfileRevision,
  });
  Future<ManagedTablet> heartbeat(
    ManagedTablet current, {
    required String clientVersion,
    required int appliedProfileRevision,
  });
  Future<ManagedTablet> refresh(ManagedTablet current);
  Future<ManagedTabletCommandPage> poll(
    ManagedTablet current, {
    required int after,
  });
  Future<ManagedTabletProfilePublication> readProfile(ManagedTablet current);
  Future<ManagedTablet> acknowledgeProfile(
    ManagedTablet current,
    ManagedTabletProfilePublication publication, {
    required String clientVersion,
  });
  Future<ManagedTabletCommand> complete(
    ManagedTablet current,
    ManagedTabletCommand command,
    TabletCommandResult result, {
    required int appliedProfileRevision,
  });
  Future<void> revoke(ManagedTablet current);
}

abstract interface class TabletFleetDeviceAuthority {
  TabletFleetDeviceBinding? currentBinding();
  Future<T> withClient<T>(
    TabletFleetDeviceBinding expected,
    Future<T> Function(TabletFleetDeviceClient client) action,
  );
}

abstract interface class TabletFleetDevicePlatform {
  Future<TabletManagementMode> managementMode();
  Future<TabletCommandResult> execute(
    TabletCommandKind command, {
    required bool Function() current,
  });
  Future<TabletCommandResult> applyProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
    required ManagedTabletProfilePublication publication,
    required bool Function() current,
  });
  Future<void> restoreProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
    required bool Function() current,
  });
  Future<void> retireProfile({
    required TabletFleetDeviceBinding binding,
    required ManagedTablet tablet,
  });
}

enum TabletFleetDeviceRuntimeStatus {
  idle,
  unenrolled,
  active,
  working,
  retired,
  unavailable,
}

final class TabletFleetDeviceRuntime extends ChangeNotifier {
  factory TabletFleetDeviceRuntime({
    required TabletFleetDeviceAuthority authority,
    required TabletFleetDeviceStore store,
    required TabletFleetDevicePlatform platform,
    required String Function() registrationId,
    required Future<String> Function() clientVersion,
  }) => TabletFleetDeviceRuntime._(
    authority,
    store,
    platform,
    registrationId,
    clientVersion,
  );
  TabletFleetDeviceRuntime._(
    this._authority,
    this._store,
    this._platform,
    this._registrationId,
    this._clientVersion,
  );

  final TabletFleetDeviceAuthority _authority;
  final TabletFleetDeviceStore _store;
  final TabletFleetDevicePlatform _platform;
  final String Function() _registrationId;
  final Future<String> Function() _clientVersion;
  TabletFleetDeviceRecord? _record;
  TabletFleetDeviceRuntimeStatus _status = TabletFleetDeviceRuntimeStatus.idle;
  String? _failure;
  bool _disposed = false;
  bool _foreground = true;
  int _generation = 0;
  Future<void>? _working;

  TabletFleetDeviceRecord? get record => _record;
  TabletFleetDeviceRuntimeStatus get status => _status;
  String? get failure => _failure;
  bool get enrolled => _record != null;
  bool get busy => _working != null;

  void _publish(TabletFleetDeviceRuntimeStatus value, [String? failure]) {
    if (_disposed) return;
    _status = value;
    _failure = failure;
    notifyListeners();
  }

  Future<void> initialize() => _serial(() async {
    final generation = ++_generation;
    final binding = _authority.currentBinding();
    TabletFleetDeviceRecord? stored;
    try {
      stored = await _store.read();
    } catch (_) {
      _record = null;
      _publish(TabletFleetDeviceRuntimeStatus.unavailable, 'storage_failed');
      return;
    }
    if (stored != null && stored.binding != binding) {
      await _platform.retireProfile(
        binding: stored.binding,
        tablet: stored.tablet,
      );
      await _store.write(null);
      stored = null;
    }
    _record = stored;
    if (stored != null) {
      final exact = stored;
      await _platform.restoreProfile(
        binding: exact.binding,
        tablet: exact.tablet,
        current: () => _current(generation, exact.binding),
      );
      if (!_current(generation, exact.binding)) {
        await _retireLocal();
        return;
      }
    }
    _publish(
      binding == null
          ? TabletFleetDeviceRuntimeStatus.retired
          : stored == null
          ? TabletFleetDeviceRuntimeStatus.unenrolled
          : TabletFleetDeviceRuntimeStatus.active,
    );
  });

  Future<void> enroll(String name) => _serial(() => _enroll(name));

  Future<void> _enroll(String name) async {
    final binding = _authority.currentBinding();
    if (binding == null || !_validName(name)) {
      throw const LarenorServerException('invalid_request');
    }
    if (_record != null) return;
    final generation = ++_generation;
    _publish(TabletFleetDeviceRuntimeStatus.working);
    try {
      final version = await _clientVersion();
      final mode = await _platform.managementMode();
      if (!_current(generation, binding)) {
        throw const LarenorServerException('retired');
      }
      final tablet = await _authority.withClient(
        binding,
        (client) => client.register(
          registrationId: _registrationId(),
          name: name,
          clientVersion: version,
          mode: mode,
          appliedProfileRevision: 1,
        ),
      );
      if (!_current(generation, binding) ||
          tablet.context.coreId != binding.coreId ||
          tablet.context.homeId != binding.homeId ||
          tablet.mode != mode ||
          tablet.state != TabletFleetState.active) {
        throw const LarenorServerException('retired');
      }
      final next = TabletFleetDeviceRecord.enrolled(
        binding: binding,
        tablet: tablet,
      );
      await _store.write(next);
      if (!_current(generation, binding)) {
        await _store.write(null);
        throw const LarenorServerException('retired');
      }
      _record = next;
      _publish(TabletFleetDeviceRuntimeStatus.active);
    } catch (error) {
      _publish(
        TabletFleetDeviceRuntimeStatus.unavailable,
        error is LarenorServerException ? error.code : 'unavailable',
      );
      rethrow;
    }
  }

  Future<void> revoke() => _serial(_revoke);

  Future<void> _revoke() async {
    final current = _record;
    if (current == null) return;
    final generation = ++_generation;
    _publish(TabletFleetDeviceRuntimeStatus.working);
    try {
      await _authority.withClient(
        current.binding,
        (client) => client.revoke(current.tablet),
      );
      if (!_current(generation, current.binding)) {
        throw const LarenorServerException('retired');
      }
      await _store.write(null);
      _record = null;
      await _platform.retireProfile(
        binding: current.binding,
        tablet: current.tablet,
      );
      _publish(TabletFleetDeviceRuntimeStatus.unenrolled);
    } catch (error) {
      _publish(
        TabletFleetDeviceRuntimeStatus.unavailable,
        error is LarenorServerException ? error.code : 'unavailable',
      );
      rethrow;
    }
  }

  Future<void> synchronize() => _serial(() async {
    if (!_foreground || _record == null) return;
    var current = _record!;
    final generation = ++_generation;
    if (!_current(generation, current.binding)) {
      await _retireLocal();
      return;
    }
    _publish(TabletFleetDeviceRuntimeStatus.working);
    try {
      final version = await _clientVersion();
      late ManagedTablet tablet;
      try {
        tablet = await _authority.withClient(
          current.binding,
          (client) => client.heartbeat(
            current.tablet,
            clientVersion: version,
            appliedProfileRevision: current.tablet.appliedProfileRevision,
          ),
        );
      } on LarenorServerException catch (error) {
        if (error.code != 'tablet_device_changed') rethrow;
        final refreshed = await _authority.withClient(
          current.binding,
          (client) => client.refresh(current.tablet),
        );
        if (!current.tablet.sameAuthority(refreshed) ||
            refreshed.state != TabletFleetState.active) {
          throw const LarenorServerException('retired');
        }
        current = current.withTablet(refreshed);
        await _save(current, generation);
        tablet = await _authority.withClient(
          current.binding,
          (client) => client.heartbeat(
            current.tablet,
            clientVersion: version,
            appliedProfileRevision: current.tablet.appliedProfileRevision,
          ),
        );
      }
      if (!_current(generation, current.binding) ||
          !current.tablet.sameAuthority(tablet) ||
          tablet.state != TabletFleetState.active) {
        throw const LarenorServerException('retired');
      }
      current = current.withTablet(tablet);
      await _save(current, generation);

      if (current.pending != null) {
        current = await _completePending(current, generation);
      }
      final page = await _authority.withClient(
        current.binding,
        (client) => client.poll(current.tablet, after: current.after),
      );
      if (!_current(generation, current.binding) ||
          page.tabletRevision != current.tablet.revision) {
        throw const LarenorServerException('retired');
      }
      for (final command in page.commands) {
        if (command.sequence <= current.after || current.pending != null) {
          throw const LarenorServerException('invalid_response');
        }
        current = current.withPending(command);
        await _save(current, generation); // Durable reservation before effect.
        var result = TabletCommandResult.unsupported;
        if (current.tablet.supports(command.kind)) {
          if (command.kind == TabletCommandKind.syncProfile) {
            final publication = await _authority.withClient(
              current.binding,
              (client) => client.readProfile(current.tablet),
            );
            if (!_effectCurrent(generation, current.binding) ||
                publication.deviceId != current.tablet.id ||
                publication.deviceRevision != current.tablet.revision ||
                publication.revision != current.tablet.desiredProfileRevision) {
              throw const LarenorServerException('retired');
            }
            result = await _platform.applyProfile(
              binding: current.binding,
              tablet: current.tablet,
              publication: publication,
              current: () => _effectCurrent(generation, current.binding),
            );
            if (result == TabletCommandResult.succeeded) {
              final applied = await _authority.withClient(
                current.binding,
                (client) => client.acknowledgeProfile(
                  current.tablet,
                  publication,
                  clientVersion: version,
                ),
              );
              if (!_current(generation, current.binding) ||
                  !current.tablet.sameAuthority(applied) ||
                  applied.appliedProfileRevision != publication.revision ||
                  applied.desiredProfileRevision != publication.revision ||
                  applied.profileState != TabletProfileState.current) {
                throw const LarenorServerException('invalid_response');
              }
              current = current.withTablet(applied);
              await _save(current, generation);
            }
          } else {
            result = await _platform.execute(
              command.kind,
              current: () => _effectCurrent(generation, current.binding),
            );
          }
        }
        if (!_current(generation, current.binding)) {
          throw const LarenorServerException('retired');
        }
        current = current.withPendingResult(result);
        await _save(current, generation); // Durable outcome before ACK.
        current = await _completePending(current, generation);
      }
      _publish(TabletFleetDeviceRuntimeStatus.active);
    } on LarenorServerException catch (error) {
      if ({
        'retired',
        'unauthorized',
        'not_found',
        'tablet_device_inactive',
      }.contains(error.code)) {
        await _retireLocal();
      } else {
        _publish(TabletFleetDeviceRuntimeStatus.unavailable, error.code);
      }
    } catch (_) {
      _publish(TabletFleetDeviceRuntimeStatus.unavailable, 'unavailable');
    }
  });

  Future<TabletFleetDeviceRecord> _completePending(
    TabletFleetDeviceRecord current,
    int generation,
  ) async {
    final pending = current.pending!;
    // A restart with a reservation but no recorded result cannot prove whether
    // the local effect happened. Fail closed and never dispatch it again.
    final result = pending.result ?? TabletCommandResult.failed;
    if (pending.result == null) {
      current = current.withPendingResult(result);
      await _save(current, generation);
    }
    final receipt = await _authority.withClient(
      current.binding,
      (client) => client.complete(
        current.tablet,
        pending.command,
        result,
        appliedProfileRevision: current.tablet.appliedProfileRevision,
      ),
    );
    if (!_current(generation, current.binding) ||
        receipt.id != pending.command.id ||
        receipt.sequence != pending.command.sequence ||
        receipt.state != TabletCommandState.completed ||
        receipt.result != result) {
      throw const LarenorServerException('invalid_response');
    }
    final next = current.completePending();
    await _save(next, generation);
    return next;
  }

  Future<void> _save(TabletFleetDeviceRecord value, int generation) async {
    await _store.write(value);
    if (!_current(generation, value.binding)) {
      throw const LarenorServerException('retired');
    }
    _record = value;
  }

  Future<void> _retireLocal() async {
    final retiring = _record;
    _generation++;
    try {
      await _store.write(null);
      if (retiring != null) {
        await _platform.retireProfile(
          binding: retiring.binding,
          tablet: retiring.tablet,
        );
      }
    } catch (_) {
      _record = null;
      _publish(TabletFleetDeviceRuntimeStatus.unavailable, 'storage_failed');
      return;
    }
    _record = null;
    _publish(TabletFleetDeviceRuntimeStatus.retired);
  }

  Future<void> setForeground(bool value) async {
    _foreground = value;
    if (value) await synchronize();
  }

  bool _current(int generation, TabletFleetDeviceBinding binding) =>
      !_disposed &&
      generation == _generation &&
      _authority.currentBinding() == binding;

  bool _effectCurrent(int generation, TabletFleetDeviceBinding binding) =>
      _foreground && _current(generation, binding);

  Future<void> _serial(Future<void> Function() operation) {
    final existing = _working;
    late final Future<void> future;
    future = (existing ?? Future<void>.value()).then(
      (_) => operation(),
      onError: (_) => operation(),
    );
    _working = future;
    return future.whenComplete(() {
      if (identical(_working, future)) _working = null;
    });
  }

  static bool _validName(String value) =>
      value.isNotEmpty &&
      value.length <= 80 &&
      value.trim() == value &&
      !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
