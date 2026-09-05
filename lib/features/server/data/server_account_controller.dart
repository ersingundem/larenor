import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/server_models.dart';
import 'larenor_server_api.dart';
import 'server_session_store.dart';

typedef ServerApiFactory = LarenorServerApi Function(ServerEndpoint endpoint);

/// Owns the account boundary for API calls and update downloads. Cached role
/// metadata is never considered authenticated until the server has answered.
class ServerAccountController extends ChangeNotifier {
  ServerAccountController({
    required this._store,
    ServerApiFactory? apiFactory,
    DateTime Function()? clock,
  }) : _factory =
           apiFactory ?? ((endpoint) => LarenorServerApi(endpoint: endpoint)),
       _clock = clock ?? DateTime.now;

  final ServerSessionPersistence _store;
  final ServerApiFactory _factory;
  final DateTime Function() _clock;
  LarenorServerApi? _api;
  ServerSession? _session;
  bool _disposed = false;
  bool _working = false;
  bool _initialized = false;
  int _generation = 0;
  String? _failure;
  Future<void> _writes = Future.value();
  Future<ServerSession>? _refreshing;
  bool _mutationInFlight = false;

  ServerSession? get session => _session;
  bool get working => _working;
  bool get initialized => _initialized;
  String? get failure => _failure;
  int get generation => _generation;
  bool isCurrent(int generation) => !_disposed && generation == _generation;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (_initialized || _working || _disposed) return;
    final generation = ++_generation;
    _working = true;
    _mutationInFlight = false;
    _failure = null;
    _emit();
    var mutationStarted = false;
    var retryable = false;
    try {
      final stored = await _store.read();
      _check(generation);
      if (stored == null) return;
      final api = _factory(stored.endpoint);
      _api = api;
      // Validate cached access through a read first. A temporarily offline
      // server must not erase a reusable refresh token during app startup.
      ServerSession? fresh;
      if (!stored.expiresSoon(_clock())) {
        try {
          fresh = stored.withUser(await api.me(stored.accessToken));
        } on LarenorServerException catch (error) {
          if (error.code != 'unauthorized') rethrow;
        }
      } else {
        await api.health();
      }
      if (fresh == null) {
        mutationStarted = true;
        _mutationInFlight = true;
        fresh = await api.refresh(stored.refreshToken);
      }
      _checkIdentity(stored, fresh);
      await _accept(fresh, generation);
    } catch (error) {
      if (isCurrent(generation)) {
        retryable =
            !mutationStarted &&
            {
              'connection_failed',
              'timeout',
              'server_error',
              'rate_limited',
            }.contains(_safeCode(error));
        if (retryable) {
          _api?.close();
          _api = null;
          _failure = _safeCode(error);
        } else {
          await _reject(error, generation);
        }
      }
    } finally {
      if (isCurrent(generation)) {
        _mutationInFlight = false;
        _initialized = !retryable;
        _working = false;
        _emit();
      }
    }
  }

  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
    required String deviceName,
  }) async {
    if (_disposed) return;
    if (_session != null) {
      throw const LarenorServerException('already_signed_in');
    }
    final generation = ++_generation;
    _api?.close();
    _refreshing = null;
    _mutationInFlight = false;
    _working = true;
    _failure = null;
    _emit();
    try {
      final ServerEndpoint endpoint;
      try {
        endpoint = ServerEndpoint(baseUrl);
      } catch (_) {
        throw const LarenorServerException('invalid_url');
      }
      final api = _factory(endpoint);
      _api = api;
      _mutationInFlight = true;
      final value = await api.login(
        username: username,
        password: password,
        deviceName: deviceName,
      );
      await _accept(value, generation);
    } catch (error) {
      if (isCurrent(generation)) await _reject(error, generation);
    } finally {
      if (isCurrent(generation)) {
        _mutationInFlight = false;
        _initialized = true;
        _working = false;
        _emit();
      }
    }
  }

  Future<ServerSession> ensureSession() {
    final session = _session;
    if (_disposed || session == null) {
      return Future.error(const LarenorServerException('unauthorized'));
    }
    if (_working) {
      return Future.error(const LarenorServerException('busy'));
    }
    if (_refreshing case final Future<ServerSession> pending) return pending;
    if (!session.expiresSoon(_clock())) return Future.value(session);
    final generation = _generation;
    final future = _rotate(session, generation);
    _refreshing = future;
    // Clear the single flight without creating an unhandled error future.
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_refreshing, future)) _refreshing = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_refreshing, future)) _refreshing = null;
        },
      ),
    );
    return future;
  }

  Future<ServerSession> _rotate(ServerSession previous, int generation) async {
    _mutationInFlight = true;
    try {
      final next = await _api!.refresh(previous.refreshToken);
      _checkIdentity(previous, next);
      await _accept(next, generation);
      _emit();
      return next;
    } catch (error) {
      if (isCurrent(generation)) await _reject(error, generation);
      // Refresh may have reached the server before a network timeout. Retrying
      // that token could revoke the family, so require a fresh login instead.
      throw LarenorServerException(_safeCode(error));
    } finally {
      if (isCurrent(generation)) _mutationInFlight = false;
    }
  }

  Future<T> withSession<T>(
    Future<T> Function(LarenorServerApi api, ServerSession session) action, {
    bool requiresReady = true,
  }) async {
    final generation = _generation;
    final current = await ensureSession();
    _check(generation);
    if (requiresReady && current.user.mustChangePassword) {
      throw const LarenorServerException('password_change_required');
    }
    try {
      final result = await action(_api!, current);
      _check(generation);
      return result;
    } on LarenorServerException catch (error) {
      if (error.code == 'unauthorized' && isCurrent(generation)) {
        await _reject(error, generation);
      }
      rethrow;
    }
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (_disposed || _working) return;
    final generation = _generation;
    try {
      final previous = await ensureSession();
      _check(generation);
      _working = true;
      _mutationInFlight = true;
      _failure = null;
      _emit();
      final next = await _api!.changePassword(
        accessToken: previous.accessToken,
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      _checkIdentity(previous, next);
      await _accept(next, generation);
    } catch (error) {
      if (isCurrent(generation)) {
        _failure = _safeCode(error);
        // Only a known rejection can safely keep the previous tokens. A lost
        // successful password-change response has already revoked them.
        if (!{
          'invalid_request',
          'rate_limited',
          'forbidden',
          'busy',
        }.contains(_failure)) {
          await _reject(error, generation);
        }
      }
    } finally {
      if (isCurrent(generation)) {
        _mutationInFlight = false;
        _working = false;
        _emit();
      }
    }
  }

  Future<void> signOut() async {
    if (_disposed) return;
    final old = _session;
    final generation = ++_generation;
    _api?.close();
    _api = null;
    _session = null;
    _refreshing = null;
    _mutationInFlight = false;
    _working = false;
    _initialized = true;
    _failure = null;
    _emit();
    try {
      await _persist(null, generation);
    } catch (_) {
      if (isCurrent(generation)) _failure = 'storage_failed';
    }
    if (old != null) {
      final api = _factory(old.endpoint);
      try {
        await api.logout(old);
      } catch (_) {
        if (isCurrent(generation) && _failure == null) {
          _failure = 'logout_not_confirmed';
        }
      } finally {
        api.close();
      }
    }
    if (isCurrent(generation)) _emit();
  }

  /// Called when an authentication form loses its visible, unlocked context.
  /// No remote mutation is issued; an already-sent auth operation can have an
  /// unknown outcome, so its old token family is never resumed automatically.
  Future<void> cancelPending() async {
    if (_disposed || (!_working && _refreshing == null)) return;
    final mutation = _mutationInFlight;
    final generation = ++_generation;
    _api?.close();
    _api = null;
    _refreshing = null;
    _working = false;
    _mutationInFlight = false;
    _failure = 'cancelled';
    if (mutation) _session = null;
    _initialized = mutation || _session != null;
    if (_session case final ServerSession active) {
      _api = _factory(active.endpoint);
    }
    _emit();
    if (mutation) {
      try {
        await _persist(null, generation);
      } catch (_) {
        if (isCurrent(generation)) _failure = 'storage_failed';
      }
    }
    if (isCurrent(generation)) _emit();
  }

  Future<void> _accept(ServerSession value, int generation) async {
    _check(generation);
    await _persist(value, generation);
    _check(generation);
    _session = value;
    _failure = null;
  }

  Future<void> _reject(Object error, int generation) async {
    _session = null;
    _api?.close();
    _api = null;
    _failure = _safeCode(error);
    try {
      await _persist(null, generation);
    } catch (_) {
      if (isCurrent(generation)) _failure = 'storage_failed';
    }
    if (isCurrent(generation)) _emit();
  }

  Future<void> _persist(ServerSession? value, int generation) {
    final operation = _writes.then((_) async {
      _check(generation);
      await _store.write(value);
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _check(int generation) {
    if (!isCurrent(generation)) {
      throw const LarenorServerException('cancelled');
    }
  }

  void _checkIdentity(ServerSession old, ServerSession next) {
    if (old.endpoint.baseUrl != next.endpoint.baseUrl ||
        old.user.id != next.user.id) {
      throw const LarenorServerException('invalid_response');
    }
  }

  String _safeCode(Object error) =>
      error is LarenorServerException ? error.code : 'connection_failed';

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _api?.close();
    _session = null;
    super.dispose();
  }
}
