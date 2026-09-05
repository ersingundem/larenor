import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_admin_models.dart';
import 'server_admin_api.dart';

enum AdminTab { users, sessions, audit }

/// One visible administrator screen owns these read results. No persistent
/// credentials, drafts, timer polling, mutation retry or cached authority.
class ServerAdminController extends ChangeNotifier {
  ServerAdminController(this.account) {
    _accountGeneration = account.generation;
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  int _generation = 0;
  late int _accountGeneration;
  bool _disposed = false;
  bool _busy = false;
  bool get busy => _busy;
  bool needsRefresh = false;
  String? failure;
  bool changed = false;
  List<AdminUser> users = const [];
  List<AdminDeviceSession> sessions = const [];
  List<AdminAuditEvent> audit = const [];
  String? sessionsCursor, auditCursor;
  static const maxVisibleEntries = 1000;

  bool get _authorized =>
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  void _accountChanged() {
    if (account.generation != _accountGeneration ||
        account.session?.user.canAdminister != true) {
      _accountGeneration = account.generation;
      invalidate();
    }
  }

  void invalidate() {
    _generation++;
    _busy = false;
    failure = null;
    changed = false;
    needsRefresh = false;
    users = const [];
    sessions = const [];
    audit = const [];
    sessionsCursor = auditCursor = null;
    _emit();
  }

  bool _current(int epoch, int accountEpoch, bool Function() current) =>
      !_disposed &&
      epoch == _generation &&
      account.isCurrent(accountEpoch) &&
      _authorized &&
      current();

  Future<void> _run(
    bool Function() current,
    Future<void> Function(ServerAdminApi) action, {
    bool mutation = false,
  }) async {
    if (_disposed ||
        _busy ||
        !_authorized ||
        !current() ||
        (mutation && needsRefresh)) {
      return;
    }
    final epoch = _generation, accountEpoch = account.generation;
    _busy = true;
    failure = null;
    changed = false;
    _emit();
    try {
      await account.withSession((api, session) async {
        // ensureSession may await a token refresh; recheck visibility immediately
        // before dispatching the operation, not just before awaiting the account.
        if (!_current(epoch, accountEpoch, current)) {
          throw const LarenorServerException('cancelled');
        }
        await action(ServerAdminApi(api, session.accessToken));
      });
      if (!_current(epoch, accountEpoch, current)) return;
      changed = mutation;
      needsRefresh = false;
    } catch (error) {
      if (!_current(epoch, accountEpoch, current)) return;
      failure = error is LarenorServerException
          ? error.code
          : 'connection_failed';
      if (mutation) needsRefresh = true;
      if (failure == 'forbidden' ||
          failure == 'unauthorized' ||
          failure == 'password_change_required') {
        users = const [];
        sessions = const [];
        audit = const [];
      }
    } finally {
      if (!_disposed && epoch == _generation) {
        _busy = false;
        _emit();
      }
    }
  }

  Future<void> load(
    AdminTab tab, {
    required bool Function() current,
    bool more = false,
  }) async {
    if (_busy || !current()) return;
    final epoch = _generation;
    final accountEpoch = account.generation;
    await _run(current, (api) async {
      switch (tab) {
        case AdminTab.users:
          final value = await api.users();
          if (_current(epoch, accountEpoch, current)) users = value;
        case AdminTab.sessions:
          if (more &&
              (sessionsCursor == null ||
                  sessions.length >= maxVisibleEntries)) {
            return;
          }
          final value = await api.sessions(
            cursor: more ? sessionsCursor : null,
          );
          if (_current(epoch, accountEpoch, current)) {
            sessions = _merge(
              more ? sessions : const [],
              value.items,
              (item) => item.id,
            );
            sessionsCursor = value.nextCursor;
          }
        case AdminTab.audit:
          if (more &&
              (auditCursor == null || audit.length >= maxVisibleEntries)) {
            return;
          }
          final value = await api.audit(cursor: more ? auditCursor : null);
          if (_current(epoch, accountEpoch, current)) {
            audit = _merge(
              more ? audit : const [],
              value.items,
              (item) => item.id,
            );
            auditCursor = value.nextCursor;
          }
      }
    });
  }

  Future<void> create({
    required String username,
    required ServerRole role,
    required String password,
    required bool Function() current,
  }) => _save(
    current,
    (api) => api.create(username: username, role: role, password: password),
  );

  Future<void> update(
    AdminUser user, {
    required ServerRole role,
    required bool disabled,
    required bool Function() current,
  }) =>
      _save(current, (api) => api.update(user, role: role, disabled: disabled));

  Future<void> resetPassword(
    AdminUser user,
    String password, {
    required bool Function() current,
  }) async {
    if (user.id == account.session?.user.id) return;
    await _save(current, (api) => api.resetPassword(user, password));
  }

  Future<void> _save(
    bool Function() current,
    Future<AdminUser> Function(ServerAdminApi) action,
  ) async {
    final epoch = _generation, accountEpoch = account.generation;
    await _run(current, (api) async {
      final value = await action(api);
      if (_current(epoch, accountEpoch, current)) {
        if (value.id == account.session?.user.id &&
            (value.disabled || value.role != ServerRole.admin)) {
          // The server revokes this user's sessions with the access change.
          // Let withSession discard the now-invalid local credentials before
          // another action can rely on the cached administrator role.
          throw const LarenorServerException('unauthorized');
        }
        users = List.unmodifiable(
          [...users.where((user) => user.id != value.id), value]
            ..sort((a, b) => a.username.compareTo(b.username)),
        );
      }
    }, mutation: true);
  }

  Future<void> revoke(
    AdminDeviceSession session, {
    required bool Function() current,
  }) async {
    final epoch = _generation, accountEpoch = account.generation;
    await _run(current, (api) async {
      await api.revoke(session.id);
      if (!_current(epoch, accountEpoch, current)) return;
      final fresh = await api.sessions();
      if (_current(epoch, accountEpoch, current)) {
        sessions = fresh.items;
        sessionsCursor = fresh.nextCursor;
      }
    }, mutation: true);
  }

  List<T> _merge<T>(List<T> previous, List<T> next, String Function(T) id) {
    final result = {for (final item in previous) id(item): item};
    for (final item in next) {
      result[id(item)] = item;
    }
    return List.unmodifiable(result.values.take(maxVisibleEntries));
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
