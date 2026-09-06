import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;

import '../../../core/configuration_writes.dart';
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
final keeneticClientFactoryProvider = Provider<KeeneticClientFactory>(
  (ref) =>
      (config, health) => KeeneticClient(config: config, healthSession: health),
);

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
  @override
  Future<KeeneticConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    _access.check();
    final generation = ++_generation;
    ref.onDispose(() {
      _generation++;
      _verificationClient?.dispose();
    });
    final value = await ref.watch(keeneticCredentialsStoreProvider).read();
    _access.check();
    if (!ref.mounted || generation != _generation) {
      throw const DirectHomeAccessException('unavailable');
    }
    return value;
  }

  Future<void> signIn({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final previous = state.value;
    final generation = ++_generation;
    _verificationClient?.dispose();
    state = const AsyncLoading();
    KeeneticClient? client;
    bool current() => ref.mounted && generation == _generation;
    try {
      final config = KeeneticConfig(
        baseUrl: KeeneticConfig.normalizeBaseUrl(baseUrl),
        username: username,
        password: password,
      );
      client = ref.read(keeneticClientFactoryProvider)(config, null);
      _verificationClient = client;
      await client.login();
      if (!current()) return;
      await client.checkConnection();
      await ConfigurationWrites.run(() async {
        if (!current()) return;
        await ref
            .read(keeneticCredentialsStoreProvider)
            .save(
              baseUrl: config.baseUrl,
              username: username,
              password: password,
            );
        if (current()) state = AsyncData(config);
      });
    } catch (_) {
      if (current()) state = AsyncData(previous);
      throw KeeneticApiException(
        'Could not sign in — check URL and credentials.',
      );
    } finally {
      client?.dispose();
      if (identical(client, _verificationClient)) _verificationClient = null;
    }
  }

  Future<void> signOut() async {
    final generation = ++_generation;
    _verificationClient?.dispose();
    state = const AsyncLoading();
    await ConfigurationWrites.run(() async {
      if (!ref.mounted || generation != _generation) return;
      await ref.read(keeneticCredentialsStoreProvider).clear();
      if (ref.mounted && generation == _generation) {
        state = const AsyncData(null);
      }
    });
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
