import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_resource_models.dart';
import 'home_resources_api.dart';
import 'home_resource_admin_api.dart';

enum HomeResourceMutationOutcome { saved, deleted, conflict, uncertain, failed }

/// Visible, session-owned metadata; neither a persistent cache nor an ACL lease.
class HomeResourcesController extends ChangeNotifier {
  HomeResourcesController(
    this.home,
    this.factory,
    this.clock,
    this.windowCurrent, {
    this.adminManagement = false,
  }) {
    home.addListener(_changed);
    home.account.addListener(_changed);
  }
  final HomeSessionController home;
  final ServerApiFactory factory;
  final DateTime Function() clock;
  final bool Function() windowCurrent;
  final bool adminManagement;
  HomeResourceMutationOutcome? mutationOutcome;
  bool _disposed = false,
      _visible = false,
      _attempted = false,
      _preparing = false;
  int epoch = 0;
  bool busy = false, loaded = false;
  String? failure, nextAfter, _snapshot;
  List<HomeResourceRecord> entries = const [];
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
    final account = home.account;
    final session = account.session;
    if (!_sourceCurrent ||
        !account.initialized ||
        account.working ||
        account.hasPendingContext ||
        session == null ||
        session.context == null ||
        session.authMutationPending ||
        session.user.mustChangePassword ||
        (adminManagement && !session.user.canAdminister)) {
      return null;
    }
    return session;
  }

  bool get fresh => _ready != null && !_ready!.expiresSoon(clock());
  bool get canRefresh => _ready != null && !busy;
  bool get canLoadMore => fresh && !busy && nextAfter != null;
  bool get canManage => fresh && _ready!.user.canAdminister;
  bool get canMutate => adminManagement && canManage && loaded && !busy;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _clear() {
    entries = const [];
    nextAfter = null;
    _snapshot = null;
    loaded = false;
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
    mutationOutcome = null;
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
    // Auth refresh owns its context GET. Hide rows while it binds the candidate;
    // never cancel that shared account operation from this read-only page.
    if (_preparing && (_preparationCurrent?.call() ?? false)) {
      _clear();
      _emit();
      return;
    }
    if (!fresh ||
        (_boundSession != null && !identical(_boundSession, _ready))) {
      _retire();
      _attempted = false;
    }
    _emit();
    _startIfReady();
  }

  Future<void> refresh() => _load(more: false);
  Future<void> loadMore() => _load(more: true);
  Future<void> _load({required bool more}) async {
    final original = _ready;
    if (original == null || busy || (more && !canLoadMore)) return;
    final generation = home.account.generation,
        homeEpoch = home.interaction.epoch;
    final operation = ++epoch;
    final previous = entries,
        cursor = more ? nextAfter : null,
        snapshot = more ? _snapshot : null;
    bool current() =>
        !_disposed &&
        epoch == operation &&
        _sourceCurrent &&
        home.interaction.epoch == homeEpoch &&
        home.account.isCurrent(generation);
    bool sameScope(ServerSession session) =>
        session.context == original.context &&
        session.user.id == original.user.id &&
        session.endpoint.baseUrl == original.endpoint.baseUrl;
    if (!more) {
      _clear();
      mutationOutcome = null;
    }
    busy = true;
    failure = null;
    _attempted = true;
    _preparing = true;
    _preparationCurrent = current;
    _emit();
    HomeResourcePage? page;
    try {
      await home.account.withSession((_, session) async {
        if (!current() || !sameScope(session) || !fresh) {
          throw const LarenorServerException('cancelled');
        }
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
        _transport = factory(session.endpoint);
        try {
          page = await HomeResourcesApi(
            _transport!,
            session.accessToken,
            session.context!,
          ).list(after: cursor, snapshot: snapshot);
        } catch (_) {
          // Only the still-authoritative read may revoke this account on 401.
          // Closing this page's transport does not guarantee an HTTP error was
          // not already delivered by the underlying client.
          if (!current() || !identical(_ready, session) || !fresh) {
            throw const LarenorServerException('cancelled');
          }
          rethrow;
        }
        if (!current() || !identical(_ready, session) || !fresh) {
          throw const LarenorServerException('cancelled');
        }
      });
      if (!current() || !fresh || page == null) return;
      final combined = [...previous.where((_) => more), ...page!.entries];
      if (combined.length > HomeResourcePage.maximumRecords ||
          combined.length == HomeResourcePage.maximumRecords &&
              page!.nextAfter != null) {
        throw const LarenorServerException('invalid_response');
      }
      entries = List.unmodifiable(combined);
      nextAfter = page!.nextAfter;
      _snapshot = page!.snapshot;
      loaded = true;
    } catch (error) {
      if (current()) {
        _clear();
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
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

  bool _knownTarget(HomeResourceRecord target) => entries.any(
    (entry) =>
        entry.context == target.context &&
        entry.id == target.id &&
        entry.kind == target.kind &&
        entry.revision == target.revision &&
        entry.aclRevision == target.aclRevision,
  );

  Future<void> create({
    required HomeResourceKind kind,
    required String label,
    required int order,
    required bool Function() isCurrent,
  }) => _mutate(
    (api) => api.create(kind: kind, label: label, order: order),
    isCurrent,
  );

  Future<void> update(
    HomeResourceRecord target, {
    required String label,
    required int order,
    required bool Function() isCurrent,
  }) async {
    if (!_knownTarget(target)) return;
    await _mutate(
      (api) => api.update(target, label: label, order: order),
      isCurrent,
    );
  }

  Future<void> delete(
    HomeResourceRecord target, {
    required bool Function() isCurrent,
  }) async {
    if (!_knownTarget(target)) return;
    await _mutate(
      (api) async {
        await api.delete(target);
        return null;
      },
      isCurrent,
      deleted: target,
    );
  }

  Future<void> _mutate(
    Future<HomeResourceRecord?> Function(HomeResourceAdminApi) action,
    bool Function() owner, {
    HomeResourceRecord? deleted,
  }) async {
    bool ownerCurrent() {
      try {
        return owner();
      } catch (_) {
        return false;
      }
    }

    if (!canMutate || !ownerCurrent()) return;
    final original = _ready!,
        generation = home.account.generation,
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
    busy = true;
    failure = null;
    mutationOutcome = null;
    _attempted = true;
    _preparing = true;
    _preparationCurrent = current;
    _emit();
    HomeResourceRecord? result;
    try {
      await home.account.withSession((_, session) async {
        if (!current() || !sameScope(session) || !canManage) {
          throw const LarenorServerException('cancelled');
        }
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
        _transport = factory(session.endpoint);
        try {
          result = await action(
            HomeResourceAdminApi(
              _transport!,
              session.accessToken,
              session.context!,
            ),
          );
        } catch (_) {
          // A retired mutation must not pass its late 401 to shared auth.
          if (!current() || !identical(_ready, session) || !canManage) {
            throw const LarenorServerException('cancelled');
          }
          rethrow;
        }
        if (!current() || !identical(_ready, session) || !canManage) {
          throw const LarenorServerException('cancelled');
        }
      });
      if (!current() || !canManage) return;
      final next = entries
          .where((entry) => entry.id != (deleted?.id ?? result?.id))
          .toList();
      if (deleted == null) {
        if (result == null || next.length >= HomeResourcePage.maximumRecords) {
          throw const LarenorServerException('invalid_response');
        }
        next.add(result!);
      }
      entries = List.unmodifiable(next);
      // A known write invalidates the prior paging snapshot. A fresh list is
      // explicit; a possibly completed POST is never repeated to recover it.
      nextAfter = null;
      _snapshot = null;
      loaded = true;
      mutationOutcome = deleted == null
          ? HomeResourceMutationOutcome.saved
          : HomeResourceMutationOutcome.deleted;
    } catch (error) {
      if (current()) {
        _clear();
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
        mutationOutcome = switch (failure) {
          'revision_conflict' ||
          'conflict' => HomeResourceMutationOutcome.conflict,
          'invalid_request' ||
          'forbidden' ||
          'not_found' => HomeResourceMutationOutcome.failed,
          _ => HomeResourceMutationOutcome.uncertain,
        };
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
