import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/core_proxmox_models.dart';
import 'core_proxmox_api.dart';

/// One mounted Core resource owner. It retains no Direct Proxmox client,
/// credentials or fallback and publishes only current-session observations.
class CoreProxmoxController extends ChangeNotifier {
  CoreProxmoxController(
    this.home,
    this.target,
    this.factory,
    this.clock,
    this.monotonic,
    this.current,
    this.owner, {
    this.admin = false,
  }) {
    home?.addListener(synchronize);
    home?.interaction.addListener(synchronize);
    home?.account.addListener(synchronize);
    owner.addListener(synchronize);
  }

  final HomeSessionController? home;
  final HomeResourceRecord target;
  final ServerApiFactory factory;
  final DateTime Function() clock;
  final Duration Function() monotonic;
  final bool Function() current;
  final Listenable owner;
  final bool admin;
  int epoch = 0;
  bool busy = false,
      loaded = false,
      uncertain = false,
      saved = false,
      _stale = false,
      _visible = false,
      _attempted = false,
      _disposed = false,
      _preparing = false;
  String? failure;
  HomeResourceRecord? record;
  CoreProxmoxBinding? binding;
  CoreProxmoxPreview? _preview;
  CoreProxmoxSnapshot? _snapshot;
  List<ServerService> services = const [];
  Timer? _authTimer, _ttlTimer;
  Duration? _deadline;
  ServerSession? _bound;
  LarenorServerApi? _transport;
  bool Function()? _preparationCurrent;
  late int _resourceRevision = target.revision,
      _aclRevision = target.aclRevision,
      _bindingRevision = 0,
      _serviceRevision = 0;

  bool get stale => _stale || _deadline != null && monotonic() >= _deadline!;
  CoreProxmoxSnapshot? get snapshot => fresh && !stale ? _snapshot : null;
  CoreProxmoxPreview? get preview => fresh && !stale ? _preview : null;

  bool get _sourceCurrent {
    try {
      return !_disposed &&
          _visible &&
          current() &&
          home != null &&
          target.kind == HomeResourceKind.resource &&
          home!.source == HomeSource.verifiedCore &&
          !home!.busy &&
          home!.failure == null &&
          home!.interaction.active;
    } catch (_) {
      return false;
    }
  }

  ServerSession? get _ready {
    final account = home?.account, session = account?.session;
    if (!_sourceCurrent ||
        account == null ||
        !account.initialized ||
        account.working ||
        account.hasPendingContext ||
        session == null ||
        session.context != target.context ||
        session.authMutationPending ||
        session.user.mustChangePassword ||
        admin && !session.user.canAdminister) {
      return null;
    }
    return session;
  }

  bool get fresh => _ready != null && !_ready!.expiresSoon(clock());
  bool get canRefresh => _ready != null && !busy;
  bool get canPreview =>
      admin && fresh && loaded && !busy && !uncertain && preview == null;
  bool get canConfirm => admin && fresh && !busy && preview != null && !stale;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _clear() {
    _ttlTimer?.cancel();
    _ttlTimer = null;
    _deadline = null;
    record = null;
    binding = null;
    _preview = null;
    _snapshot = null;
    services = const [];
    loaded = false;
    saved = false;
    _stale = false;
  }

  void _retire() {
    epoch++;
    busy = false;
    _preparing = false;
    _preparationCurrent = null;
    _transport?.close();
    _transport = null;
    _authTimer?.cancel();
    _authTimer = null;
    _bound = null;
    failure = null;
    uncertain = false;
    _clear();
  }

  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value;
    _retire();
    _attempted = false;
    _emit();
    _start();
  }

  void _start() {
    if (!_attempted && fresh) {
      _attempted = true;
      unawaited(refresh());
    }
  }

  void synchronize() {
    if (_disposed) return;
    if (_preparing && (_preparationCurrent?.call() ?? false)) {
      _clear();
      _emit();
      return;
    }
    if (!fresh || _bound != null && !identical(_bound, _ready)) {
      _retire();
      _attempted = false;
    }
    if (stale && !_stale) _expire();
    _emit();
    _start();
  }

  void _expire() {
    _snapshot = null;
    _preview = null;
    _deadline = null;
    _stale = true;
    _ttlTimer?.cancel();
    _ttlTimer = null;
  }

  void _arm(Duration deadline) {
    _ttlTimer?.cancel();
    _deadline = deadline;
    final wait = deadline - monotonic(), operation = epoch;
    if (wait <= Duration.zero) {
      _expire();
      return;
    }
    _ttlTimer = Timer(wait, () {
      if (_disposed || operation != epoch) return;
      _expire();
      _emit();
    });
  }

  bool _action(bool Function() value) {
    try {
      return value();
    } catch (_) {
      return false;
    }
  }

  Future<void> _run(
    Future<void> Function(CoreProxmoxApi Function(HomeResourceRecord)) action, {
    bool write = false,
    bool Function()? guard,
    bool Function()? responseCurrent,
  }) async {
    final original = _ready;
    if (original == null || busy || guard != null && !_action(guard)) return;
    final generation = home!.account.generation,
        homeEpoch = home!.interaction.epoch,
        operation = ++epoch;
    bool live() =>
        !_disposed &&
        epoch == operation &&
        _sourceCurrent &&
        home!.interaction.epoch == homeEpoch &&
        home!.account.isCurrent(generation) &&
        (guard == null || _action(guard));
    bool sameScope(ServerSession session) =>
        session.context == original.context &&
        session.user.id == original.user.id &&
        session.endpoint.baseUrl == original.endpoint.baseUrl;
    busy = true;
    failure = null;
    saved = false;
    _attempted = true;
    _preparing = true;
    _preparationCurrent = live;
    _emit();
    try {
      await home!.account.withSession((_, session) async {
        if (!live() ||
            !sameScope(session) ||
            !fresh ||
            responseCurrent != null && !_action(responseCurrent)) {
          throw const LarenorServerException('cancelled');
        }
        _preparing = false;
        _bound = session;
        _authTimer?.cancel();
        final remaining = session.expiresAt
            .subtract(const Duration(seconds: 30))
            .difference(clock());
        _authTimer = Timer(
          remaining.isNegative ? Duration.zero : remaining,
          synchronize,
        );
        _transport = factory(session.endpoint);
        bool authoritative() =>
            live() &&
            identical(_ready, session) &&
            fresh &&
            (responseCurrent == null || _action(responseCurrent));
        try {
          await action(
            (record) => CoreProxmoxApi(
              _transport!,
              session.accessToken,
              record,
              isCurrent: authoritative,
            ),
          );
        } catch (_) {
          if (!authoritative()) {
            throw const LarenorServerException('cancelled');
          }
          rethrow;
        }
        if (!authoritative()) throw const LarenorServerException('cancelled');
      });
      if (!live() || !fresh) return;
    } catch (error) {
      if (live()) {
        _clear();
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
        final definite = {
          'forbidden',
          'not_found',
          'invalid_request',
          'revision_conflict',
          'proxmox_binding_changed',
          'proxmox_preview_invalid',
        }.contains(failure);
        uncertain = write && !definite;
      }
    } finally {
      if (!_disposed && epoch == operation) {
        if (!live()) {
          _clear();
          failure = null;
          uncertain = false;
        }
        _transport?.close();
        _transport = null;
        _preparing = false;
        _preparationCurrent = null;
        busy = false;
        _emit();
      }
    }
  }

  Future<void> refresh() async {
    if (!canRefresh) return;
    _clear();
    uncertain = false;
    await _run((api) async {
      final next = await api(target).resource();
      if (next.revision < _resourceRevision ||
          next.aclRevision < _aclRevision) {
        throw const LarenorServerException('invalid_response');
      }
      _resourceRevision = next.revision;
      _aclRevision = next.aclRevision;
      record = next;
      if (admin) {
        final value = await api(next).binding();
        if ((value?.revision ?? 0) < _bindingRevision) {
          throw const LarenorServerException('proxmox_binding_changed');
        }
        _bindingRevision = value?.revision ?? 0;
        _serviceRevision = value?.serviceRevision ?? 0;
        binding = value;
        services = await api(next).services();
      } else {
        final started = monotonic(), value = await api(next).snapshot();
        if (value.bindingRevision < _bindingRevision ||
            value.serviceRevision < _serviceRevision ||
            value.resourceRevision != next.revision ||
            value.aclRevision != next.aclRevision) {
          throw const LarenorServerException('proxmox_binding_changed');
        }
        _bindingRevision = value.bindingRevision;
        _serviceRevision = value.serviceRevision;
        _snapshot = value;
        _arm(started + value.remainingTtl);
      }
      loaded = true;
    });
  }

  Future<void> prepare(
    ServerService service, {
    required bool Function() isCurrent,
  }) async {
    if (!canPreview ||
        !services.any((value) => identical(value, service)) ||
        !_action(isCurrent)) {
      return;
    }
    final currentRecord = record!, existing = binding;
    await _run((api) async {
      final started = monotonic();
      final value = await api(currentRecord)
          .preview(service: service, existing: existing);
      _preview = value;
      _stale = false;
      _arm(started + Duration(milliseconds: value.expiresInMs));
    }, guard: isCurrent);
  }

  Future<void> confirm(
    CoreProxmoxPreview value, {
    required bool Function() isCurrent,
  }) async {
    if (!canConfirm || !identical(value, preview) || !_action(isCurrent)) {
      return;
    }
    final deadline = _deadline!, currentRecord = record!;
    _preview = null;
    _ttlTimer?.cancel();
    _deadline = null;
    await _run(
      (api) async {
        final result = await api(currentRecord).confirm(value);
        binding = result;
        _bindingRevision = result.revision;
        _serviceRevision = result.serviceRevision;
        saved = true;
      },
      write: true,
      guard: isCurrent,
      responseCurrent: () => monotonic() < deadline,
    );
  }

  Future<void> cancel(
    CoreProxmoxPreview value, {
    required bool Function() isCurrent,
  }) async {
    if (!canConfirm || !identical(value, preview) || !_action(isCurrent)) {
      return;
    }
    final currentRecord = record!;
    _preview = null;
    _ttlTimer?.cancel();
    _deadline = null;
    _emit();
    await _run((api) => api(currentRecord).cancel(value), guard: isCurrent);
  }

  @override
  void dispose() {
    home?.removeListener(synchronize);
    home?.interaction.removeListener(synchronize);
    home?.account.removeListener(synchronize);
    owner.removeListener(synchronize);
    _retire();
    _disposed = true;
    super.dispose();
  }
}
