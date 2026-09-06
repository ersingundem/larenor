import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/admin/data/server_admin_api.dart';
import '../../server/admin/domain/server_admin_models.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_resource_grants.dart';
import '../domain/home_resource_models.dart';
import 'home_resource_grants_api.dart';

enum HomeResourceGrantOutcome { saved, revoked, conflict, uncertain, failed }

/// One visible admin session owns this selection and its transport. Stored ACLs
/// do not confer authority on this client or change account roles.
class HomeResourceGrantsController extends ChangeNotifier {
  HomeResourceGrantsController(
    this.home,
    this.target,
    this.factory,
    this.clock,
    this.windowCurrent,
  ) : _minimumAclRevision = target.aclRevision {
    home.addListener(_changed);
    home.account.addListener(_changed);
  }
  final HomeSessionController home;
  final HomeResourceRecord target;
  final ServerApiFactory factory;
  final DateTime Function() clock;
  final bool Function() windowCurrent;
  bool _disposed = false,
      _visible = false,
      _attempted = false,
      _preparing = false;
  bool busy = false;
  int epoch = 0;
  int _minimumAclRevision;
  String? failure;
  HomeResourceGrantOutcome? outcome;
  List<AdminUser> users = const [];
  HomeResourceGrants? snapshot;
  LarenorServerApi? _transport;
  ServerSession? _boundSession;
  Timer? _expiry;
  bool Function()? _preparationCurrent;

  bool get _sourceCurrent =>
      !_disposed &&
      _visible &&
      windowCurrent() &&
      home.source == HomeSource.verifiedCore &&
      !home.busy &&
      home.failure == null &&
      home.interaction.active;
  ServerSession? get _ready {
    final account = home.account, session = account.session;
    if (!_sourceCurrent ||
        !account.initialized ||
        account.working ||
        account.hasPendingContext ||
        session == null ||
        session.context != target.context ||
        session.authMutationPending ||
        session.user.mustChangePassword ||
        !session.user.canAdminister) {
      return null;
    }
    return session;
  }

  bool get fresh => _ready != null && !_ready!.expiresSoon(clock());
  bool get canRefresh => _ready != null && !busy;
  bool get canChange => fresh && !busy && snapshot != null;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _clear() {
    users = const [];
    snapshot = null;
  }

  void _retire() {
    epoch++;
    busy = false;
    _preparing = false;
    _preparationCurrent = null;
    _transport?.close();
    _transport = null;
    _expiry?.cancel();
    _expiry = null;
    _boundSession = null;
    failure = null;
    outcome = null;
    _clear();
  }

  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value;
    _retire();
    _attempted = false;
    _emit();
    _startIfReady();
  }

  void _startIfReady() {
    if (!_attempted && fresh) {
      _attempted = true;
      unawaited(refresh());
    }
  }

  void _changed() {
    if (_disposed) return;
    if (_preparing && (_preparationCurrent?.call() ?? false)) {
      _clear();
      _emit();
      return;
    }
    if (!fresh || _boundSession != null && !identical(_boundSession, _ready)) {
      _retire();
      _attempted = false;
    }
    _emit();
    _startIfReady();
  }

  Future<void> refresh() async {
    if (!canRefresh) return;
    await _run(null, null, () => true);
  }

  Future<void> setPermission(
    AdminUser selected,
    HomeResourcePermission permission, {
    required bool Function() isCurrent,
  }) async {
    // Only an actual selection from this read may name an account. A caller's
    // invented AdminUser, even with the same id, is not a selection lease.
    if (!canChange || !users.any((user) => identical(user, selected))) return;
    await _run(selected, permission, isCurrent);
  }

  Future<void> _run(
    AdminUser? selected,
    HomeResourcePermission? permission,
    bool Function() owner,
  ) async {
    bool ownerCurrent() {
      try {
        return owner();
      } catch (_) {
        return false;
      }
    }

    final original = _ready;
    if (original == null || busy || !ownerCurrent()) return;
    final writing = selected != null, before = snapshot;
    final generation = home.account.generation,
        homeEpoch = home.interaction.epoch,
        operation = ++epoch;
    bool current() =>
        !_disposed &&
        epoch == operation &&
        _sourceCurrent &&
        home.interaction.epoch == homeEpoch &&
        home.account.isCurrent(generation) &&
        ownerCurrent();
    bool sameScope(ServerSession session) =>
        session.context == original.context &&
        session.user.id == original.user.id &&
        session.endpoint.baseUrl == original.endpoint.baseUrl;
    if (!writing) _clear();
    busy = true;
    failure = null;
    outcome = null;
    _attempted = true;
    _preparing = true;
    _preparationCurrent = current;
    _emit();
    HomeResourceGrants? result;
    List<AdminUser>? nextUsers;
    try {
      await home.account.withSession((_, session) async {
        void check() {
          if (!current() ||
              !sameScope(session) ||
              !identical(_ready, session) ||
              !fresh) {
            throw const LarenorServerException('cancelled');
          }
        }

        check();
        _preparing = false;
        _boundSession = session;
        _expiry?.cancel();
        final remaining = session.expiresAt
            .subtract(const Duration(seconds: 30))
            .difference(clock());
        _expiry = Timer(
          remaining.isNegative ? Duration.zero : remaining,
          _changed,
        );
        final transport = factory(session.endpoint);
        _transport = transport;
        final api = HomeResourceGrantsApi(
          transport,
          session.accessToken,
          session.context!,
        );
        try {
          if (writing) {
            result = await api.set(
              before!,
              subjectId: selected.id,
              permission: permission!,
            );
            check();
          } else {
            nextUsers = await ServerAdminApi(
              transport,
              session.accessToken,
            ).users();
            check();
            if (nextUsers!.any(
              (user) => !HomeResourceGrants.isSubjectId(user.id),
            )) {
              throw const LarenorServerException('invalid_response');
            }
            result = await api.read(target);
            check();
            if (result!.aclRevision < _minimumAclRevision) {
              throw const LarenorServerException('invalid_response');
            }
          }
        } catch (_) {
          // Retired 401s never reach shared auth and log out a newer account.
          check();
          rethrow;
        }
      });
      if (!current() || !fresh || result == null) return;
      _minimumAclRevision = result!.aclRevision;
      snapshot = result;
      if (!writing) users = List.unmodifiable(nextUsers!);
      if (writing) {
        outcome = permission == HomeResourcePermission.none
            ? HomeResourceGrantOutcome.revoked
            : HomeResourceGrantOutcome.saved;
      }
    } catch (error) {
      if (current()) {
        _clear();
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
        if (writing) {
          outcome = switch (failure) {
            'revision_conflict' ||
            'conflict' => HomeResourceGrantOutcome.conflict,
            'invalid_request' ||
            'forbidden' ||
            'not_found' => HomeResourceGrantOutcome.failed,
            _ => HomeResourceGrantOutcome.uncertain,
          };
        }
      }
    } finally {
      if (!_disposed && epoch == operation) {
        _transport?.close();
        _transport = null;
        _preparing = false;
        _preparationCurrent = null;
        busy = false;
        _emit();
      }
    }
  }

  @override
  void dispose() {
    home.removeListener(_changed);
    home.account.removeListener(_changed);
    _retire();
    _disposed = true;
    super.dispose();
  }
}
