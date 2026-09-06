import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;

import '../../../core/direct_home_access.dart';
import '../../health/data/health_monitor.dart';
import '../../health/data/integration_health.dart';
import '../../health/providers/health_providers.dart';
import '../data/keenetic_api_exception.dart';

import '../data/keenetic_client.dart';
import '../data/keenetic_config.dart';
import '../data/keenetic_credentials_store.dart';
import '../data/models/keenetic_access_point.dart';
import '../data/models/keenetic_device.dart';
import '../data/models/keenetic_port_forward.dart';
import '../data/models/keenetic_router_status.dart';

part 'keenetic_providers.g.dart';

typedef KeeneticClientFactory = KeeneticClient Function(
  KeeneticConfig config,
  HealthSession? health,
);
final keeneticClientFactoryProvider = Provider<KeeneticClientFactory>((ref) {
  final access = ref.watch(directHomeAccessProvider);
  return (config, health) {
    access.check();
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    return KeeneticClient(
      config: config,
      healthSession: health,
      isCurrent: () => ref.mounted && access.isCurrent,
    );
  };
});

final keeneticHealthSessionProvider = Provider.autoDispose<HealthSession>((
  ref,
) {
  final connection = ref.watch(keeneticConnectionProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  final session = ref
      .watch(healthMonitorProvider)
      .bind(
        IntegrationId.keenetic,
        configured: config != null,
        configurationIdentity: config,
      );
  ref.onDispose(session.close);
  return session;
});

@riverpod
KeeneticCredentialsStore keeneticCredentialsStore(Ref ref) =>
    KeeneticCredentialsStore(access: ref.watch(directHomeAccessProvider));

@Riverpod(retry: _noRetry)
class KeeneticConnection extends _$KeeneticConnection {
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  int _generation = 0;
  KeeneticClient? _verificationClient;
  bool Function()? _verificationOwner;
  int? _verificationGeneration;
  bool _publishingLoading = false;

  /// Only the synchronous loading publication for this exact form action.
  /// An external reload cannot borrow this one-shot transition.
  bool publishesLoadingFor(bool Function() owner) =>
      _publishingLoading && ownsVerification(owner);

  /// Reload can occur while already loading without another loading emission.
  bool ownsVerification(bool Function() owner) =>
      identical(owner, _verificationOwner) &&
      _verificationGeneration == _generation;

  void _check([int? generation]) {
    if (!ref.mounted) throw const DirectHomeAccessException('unavailable');
    _access.check();
    if (generation != null && generation != _generation) {
      throw KeeneticApiException('Connection is no longer active.');
    }
  }

  void _closeCheck() {
    _verificationClient?.dispose();
    _verificationClient = null;
    _verificationOwner = null;
    _verificationGeneration = null;
  }

  /// Cancels only this form's current verification transport. This performs no
  /// storage, normal reader login, retry or rollback of an already sent request.
  void cancelSignIn(bool Function() owner) {
    if (identical(_verificationOwner, owner) &&
        _verificationGeneration == _generation) {
      _verificationClient?.dispose();
    }
  }

  @override
  Future<KeeneticConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    final generation = ++_generation;
    ref.onDispose(() {
      _generation++;
      _closeCheck();
    });
    _check(generation);
    final value = await ref.watch(keeneticCredentialsStoreProvider).read();
    _check(generation);
    return value;
  }

  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
    bool Function()? isCurrent,
  }) async {
    void checkAction() {
      try {
        if (isCurrent == null || isCurrent()) return;
      } catch (_) {}
      throw const DirectHomeAccessException('unavailable');
    }

    _check();
    checkAction();
    final previous = state;
    final generation = ++_generation;
    final store = ref.read(keeneticCredentialsStoreProvider);
    final factory = ref.read(keeneticClientFactoryProvider);
    _closeCheck();
    KeeneticClient? client;
    bool current() =>
        ref.mounted && _access.isCurrent && _generation == generation;
    bool actionCurrent() {
      if (!current()) return false;
      try {
        return isCurrent == null || isCurrent();
      } catch (_) {
        return false;
      }
    }

    try {
      _verificationOwner = isCurrent;
      _verificationGeneration = generation;
      // Retire a former reader without cancelling this form's own transition.
      if (!previous.isLoading && !previous.hasError && previous.value != null) {
        _publishingLoading = true;
        try {
          state = const AsyncLoading();
        } finally {
          _publishingLoading = false;
        }
      }
      _check(generation);
      checkAction();
      final config = KeeneticConfig(
        baseUrl: KeeneticConfig.normalizeBaseUrl(baseUrl),
        username: username,
        password: password,
      );
      client = factory(config, null);
      _verificationClient = client;
      _verificationOwner = isCurrent;
      _verificationGeneration = generation;
      await client.login();
      _check(generation);
      checkAction();
      await client.checkConnection();
      _check(generation);
      checkAction();
      await store.save(
        baseUrl: config.baseUrl,
        username: username,
        password: password,
        isCurrent: actionCurrent,
      );
      _check(generation);
      checkAction();
      state = AsyncData(config);
    } catch (error) {
      _check(generation);
      try {
        checkAction();
      } on DirectHomeAccessException catch (expired) {
        state = AsyncError(expired, StackTrace.empty);
        rethrow;
      }
      // A possibly persisted partial tuple must never republish a usable
      // connection. Its private marker requires explicit complete recovery.
      if (error is DirectHomeAccessException) {
        state = AsyncError(error, StackTrace.empty);
        rethrow;
      }
      if (current()) {
        state = previous.isLoading
            ? AsyncError(
                const DirectHomeAccessException('unavailable'),
                StackTrace.empty,
              )
            : previous;
      }
      throw KeeneticApiException(
        'Could not sign in — check URL and credentials.',
      );
    } finally {
      client?.dispose();
      if (identical(_verificationClient, client)) {
        _verificationClient = null;
        _verificationOwner = null;
        _verificationGeneration = null;
      }
    }
  }

  Future<void> signOut({bool Function()? isCurrent}) async {
    _check();
    bool actionCurrent() {
      try {
        return isCurrent == null || isCurrent();
      } catch (_) {
        return false;
      }
    }

    if (!actionCurrent()) throw const DirectHomeAccessException('unavailable');
    final generation = ++_generation;
    final store = ref.read(keeneticCredentialsStoreProvider);
    _closeCheck();
    state = const AsyncLoading();
    try {
      await store.clear(
        isCurrent: () =>
            ref.mounted &&
            _access.isCurrent &&
            generation == _generation &&
            actionCurrent(),
      );
      _check(generation);
      if (!actionCurrent()) {
        throw const DirectHomeAccessException('unavailable');
      }
      state = const AsyncData(null);
    } catch (error) {
      _check(generation);
      state = AsyncError(
        const DirectHomeAccessException('write_unconfirmed'),
        StackTrace.empty,
      );
      rethrow;
    }
  }
}

@Riverpod(retry: _noRetry)
Future<KeeneticClient?> keeneticClient(Ref ref) async {
  final access = ref.watch(directHomeAccessProvider);
  if (!access.isCurrent) return null;
  final connection = ref.watch(keeneticConnectionProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  final health = ref.watch(keeneticHealthSessionProvider);
  if (config == null) return null;
  final client = ref.watch(keeneticClientFactoryProvider)(config, health);
  ref.onDispose(client.dispose);
  try {
    await client.login();
    access.check();
    if (!ref.mounted) {
      client.dispose();
      return null;
    }
    return client;
  } catch (_) {
    client.dispose();
    rethrow;
  }
}

@Riverpod(retry: _noRetry)
Future<KeeneticRouterStatus?> keeneticRouterStatus(Ref ref) async {
  final client = await ref.watch(keeneticClientProvider.future);
  if (!ref.mounted || client == null) return null;
  return client.getRouterStatus();
}

@Riverpod(retry: _noRetry)
Future<List<KeeneticDevice>> keeneticDevices(Ref ref) async {
  final client = await ref.watch(keeneticClientProvider.future);
  if (!ref.mounted || client == null) return [];
  return client.getConnectedDevices();
}

@Riverpod(retry: _noRetry)
Future<List<KeeneticAccessPoint>> keeneticAccessPoints(Ref ref) async {
  final client = await ref.watch(keeneticClientProvider.future);
  if (!ref.mounted || client == null) return [];
  return client.getAccessPoints();
}

@Riverpod(retry: _noRetry)
Future<List<KeeneticPortForward>> keeneticPortForwarding(Ref ref) async {
  final client = await ref.watch(keeneticClientProvider.future);
  if (!ref.mounted || client == null) return [];
  return client.getPortForwardingRules();
}

Duration? _noRetry(int retryCount, Object error) => null;
