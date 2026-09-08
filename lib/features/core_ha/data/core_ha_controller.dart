import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/core_ha_models.dart';
import 'core_ha_api.dart';

/// One selected resource, current account and mounted owner. No persistent cache,
/// device client, command dispatch, or automatic retry of binding writes.
class CoreHaController extends ChangeNotifier {
  CoreHaController(this.home, this.target, this.factory, this.clock, this.monotonic, this.current, this.owner, {this.admin = false}) {
    home?.addListener(_changed); home?.interaction.addListener(_changed);
    home?.account.addListener(_changed); owner.addListener(_changed);
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
  bool busy = false, loaded = false, stale = false, uncertain = false, saved = false;
  String? failure;
  HomeResourceRecord? record;
  CoreHaSnapshot? snapshot;
  CoreHaBinding? binding;
  CoreHaPreview? preview;
  List<ServerService> services = const [];
  bool _disposed = false, _visible = false, _attempted = false, _preparing = false;
  bool Function()? _preparationCurrent;
  ServerSession? _bound;
  LarenorServerApi? _transport;
  Timer? _authTimer, _ttlTimer;
  Duration? _deadline;
  late int _resourceRevision = target.revision, _aclRevision = target.aclRevision;
  int _bindingRevision = 0;

  bool get _sourceCurrent {
    try {
      return !_disposed && _visible && current() && home != null &&
          target.kind == HomeResourceKind.resource &&
          home!.source == HomeSource.verifiedCore && !home!.busy &&
          home!.failure == null && home!.interaction.active;
    } catch (_) { return false; }
  }
  ServerSession? get _ready {
    final account = home?.account, session = account?.session;
    if (!_sourceCurrent || account == null || !account.initialized || account.working || account.hasPendingContext || session == null || session.context != target.context || session.authMutationPending || session.user.mustChangePassword || admin && !session.user.canAdminister) return null;
    return session;
  }
  bool get fresh => _ready != null && !_ready!.expiresSoon(clock());
  bool get canRefresh => _ready != null && !busy;
  bool get canPreview => admin && fresh && loaded && !busy && !uncertain && preview == null;
  bool get canConfirm => admin && fresh && !busy && preview != null && _deadline != null && monotonic() < _deadline!;
  void _emit() { if (!_disposed) notifyListeners(); }
  void _clear() {
    _ttlTimer?.cancel(); _ttlTimer = null; _deadline = null;
    record = null; snapshot = null; binding = null; preview = null; services = const [];
    loaded = false; stale = false; saved = false;
  }
  void _retire() {
    epoch++; busy = false; _preparing = false; _preparationCurrent = null;
    _transport?.close(); _transport = null; _authTimer?.cancel(); _authTimer = null;
    _bound = null; failure = null; uncertain = false; _clear();
  }
  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value; _retire(); _attempted = false; _emit(); _start();
  }
  void _start() {
    if (!_attempted && fresh) { _attempted = true; unawaited(refresh()); }
  }
  void _changed() {
    if (_disposed) return;
    // Account refresh owns its pending context read, even while metadata hides.
    if (_preparing && (_preparationCurrent?.call() ?? false)) { _clear(); _emit(); return; }
    if (!fresh || _bound != null && !identical(_bound, _ready)) {
      _retire(); _attempted = false;
    }
    _emit(); _start();
  }
  void _expire() {
    snapshot = null; preview = null; _deadline = null; stale = true;
    _ttlTimer?.cancel(); _ttlTimer = null;
  }
  void _arm(Duration deadline) {
    _ttlTimer?.cancel(); _deadline = deadline;
    final duration = deadline - monotonic(), operation = epoch;
    if (duration <= Duration.zero) { _expire(); return; }
    _ttlTimer = Timer(duration, () {
      if (_disposed || operation != epoch) return;
      _expire(); _emit();
    });
  }
  bool _action(bool Function() check) { try { return check(); } catch (_) { return false; } }

  Future<void> _run(Future<void> Function(CoreHaApi Function(HomeResourceRecord)) action, {bool write = false, bool Function()? guard, bool Function()? responseCurrent}) async {
    final original = _ready;
    if (original == null || busy || guard != null && !_action(guard)) return;
    final generation = home!.account.generation, homeEpoch = home!.interaction.epoch, operation = ++epoch;
    bool live() => !_disposed && epoch == operation && _sourceCurrent && home!.interaction.epoch == homeEpoch && home!.account.isCurrent(generation) && (guard == null || _action(guard));
    bool sameScope(ServerSession session) => session.context == original.context && session.user.id == original.user.id && session.endpoint.baseUrl == original.endpoint.baseUrl;
    busy = true; failure = null; saved = false; _attempted = true; _preparing = true; _preparationCurrent = live; _emit();
    try {
      await home!.account.withSession((_, session) async {
        if (!live() || !sameScope(session) || !fresh || responseCurrent != null && !_action(responseCurrent)) throw const LarenorServerException('cancelled');
        _preparing = false; _bound = session;
        _authTimer?.cancel();
        final remaining = session.expiresAt.subtract(const Duration(seconds: 30)).difference(clock());
        _authTimer = Timer(remaining.isNegative ? Duration.zero : remaining, _changed);
        _transport = factory(session.endpoint);
        bool authoritative() => live() && identical(_ready, session) && fresh && (responseCurrent == null || _action(responseCurrent));
        try {
          await action((record) => CoreHaApi(_transport!, session.accessToken, record, isCurrent: authoritative));
        } catch (_) {
          if (!authoritative()) throw const LarenorServerException('cancelled');
          rethrow;
        }
        if (!authoritative()) throw const LarenorServerException('cancelled');
      });
      if (!live() || !fresh) return;
    } catch (error) {
      if (live()) {
        _clear(); failure = error is LarenorServerException ? error.code : 'connection_failed';
        uncertain = write && !{'forbidden', 'not_found', 'invalid_request', 'revision_conflict', 'ha_binding_changed', 'ha_preview_invalid'}.contains(failure);
      }
    } finally {
      if (!_disposed && epoch == operation) {
        if (!live()) { _clear(); failure = null; uncertain = false; }
        _transport?.close(); _transport = null; _preparing = false; _preparationCurrent = null; busy = false; _emit();
      }
    }
  }
  Future<void> refresh() async {
    if (!canRefresh) return;
    _clear(); uncertain = false;
    await _run((api) async {
      final next = await api(target).resource();
      if (next.revision < _resourceRevision || next.aclRevision < _aclRevision) throw const LarenorServerException('invalid_response');
      _resourceRevision = next.revision; _aclRevision = next.aclRevision;
      record = next;
      if (admin) {
        final value = await api(next).binding();
        if ((value?.revision ?? 0) < _bindingRevision) throw const LarenorServerException('ha_binding_changed');
        _bindingRevision = value?.revision ?? 0; binding = value;
        services = await api(next).services();
      } else {
        final started = monotonic(), value = await api(next).snapshot();
        if (value.bindingRevision < _bindingRevision) throw const LarenorServerException('ha_binding_changed');
        _bindingRevision = value.bindingRevision;
        _resourceRevision = value.resourceRevision; _aclRevision = value.aclRevision;
        snapshot = value; _arm(started + Duration(milliseconds: value.remainingTtlMs));
      }
      loaded = true;
    });
  }
  Future<void> prepare(ServerService service, String entityId, {required bool Function() isCurrent}) async {
    if (!canPreview || !services.any((s) => identical(s, service)) || !_action(isCurrent)) return;
    final target = record!, existing = binding;
    await _run((api) async {
      final started = monotonic();
      final value = await api(target).preview(service: service, entityId: entityId, existing: existing);
      preview = value; stale = false; _arm(started + Duration(milliseconds: value.expiresInMs));
    }, guard: isCurrent);
  }
  Future<void> confirm(CoreHaPreview value, {required bool Function() isCurrent}) async {
    if (!canConfirm || !identical(value, preview) || !_action(isCurrent)) {
      if (preview != null && _deadline != null && monotonic() >= _deadline!) { _expire(); _emit(); }
      return;
    }
    final deadline = _deadline!, target = record!;
    preview = null; _ttlTimer?.cancel(); _deadline = null;
    await _run((api) async {
      final result = await api(target).confirm(value);
      binding = result; _bindingRevision = result.revision; saved = true;
    }, write: true, guard: isCurrent, responseCurrent: () => monotonic() < deadline);
  }
  Future<void> cancel(CoreHaPreview value, {required bool Function() isCurrent}) async {
    if (!canConfirm || !identical(value, preview) || !_action(isCurrent)) return;
    final target = record!;
    preview = null; _ttlTimer?.cancel(); _deadline = null; _emit();
    await _run((api) => api(target).cancel(value), guard: isCurrent);
  }
  @override
  void dispose() {
    home?.removeListener(_changed); home?.interaction.removeListener(_changed);
    home?.account.removeListener(_changed); owner.removeListener(_changed);
    _retire(); _disposed = true; super.dispose();
  }
}
