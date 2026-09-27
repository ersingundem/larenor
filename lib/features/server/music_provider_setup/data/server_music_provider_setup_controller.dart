import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_provider_setup_models.dart';
import 'server_music_provider_setup_api.dart';

/// Route-owned authority for one provider setup flow.
///
/// Setup mutations are never repeated automatically. When a response may have
/// been lost, the controller first reads the setup at its stable identifier and
/// accepts only the exact authoritative revision returned by Core.
final class ServerMusicProviderSetupController extends ChangeNotifier {
  ServerMusicProviderSetupController(
    this.account, {
    required this.installationId,
    required this.installationRevision,
    String Function()? requestId,
  }) : _accountEpoch = account.generation,
       _requestId = requestId ?? _randomId {
    account.addListener(_accountChanged);
  }

  final ServerAccountController account;
  final String installationId;
  final int installationRevision;
  final int _accountEpoch;
  final String Function() _requestId;
  int _epoch = 0;
  bool _disposed = false;

  bool busy = false;
  bool needsRefresh = false;
  bool createOutcomeUnknown = false;
  bool reconciled = false;
  String? failure;
  ServerMusicProviderSetupCapabilities? capabilities;
  ServerMusicProviderSetup? setup;

  static const _unknownOutcomeCodes = {
    'connection_failed',
    'timeout',
    'server_error',
    'invalid_response',
    'music_provider_setup_storage_unavailable',
  };
  static const _readbackCodes = {
    ..._unknownOutcomeCodes,
    'revision_conflict',
    'music_provider_setup_expired',
    'music_provider_capability_changed',
    'music_provider_worker_unavailable',
  };

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  bool get _authorized =>
      account.isCurrent(_accountEpoch) &&
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  bool get canCreate =>
      !busy &&
      !needsRefresh &&
      !createOutcomeUnknown &&
      capabilities != null &&
      (setup == null ||
          setup?.state == ServerMusicProviderSetupState.ready ||
          setup?.state == ServerMusicProviderSetupState.cancelled);

  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int epoch, bool Function() current) =>
      !_disposed && epoch == _epoch && _authorized && current();

  void invalidate() {
    _epoch++;
    busy = false;
    needsRefresh = false;
    createOutcomeUnknown = false;
    reconciled = false;
    failure = null;
    capabilities = null;
    setup = null;
    _emit();
  }

  Future<void> loadCapabilities({required bool Function() current}) async {
    await _read(current, (api) => api.capabilities(), (value) {
      capabilities = value;
    });
  }

  Future<void> create(
    ServerMusicProviderDomain domain, {
    required bool Function() current,
  }) async {
    if (!canCreate || !_authorized || !current()) return;
    final intent = ServerMusicProviderSetupIntent(
      requestId: _requestId(),
      installationId: installationId,
      installationRevision: installationRevision,
      domain: domain,
    );
    await _run(current, (api, valid) async {
      final value = await api.create(intent);
      if (valid()) setup = value;
    }, createMutation: true);
  }

  Future<void> refresh({required bool Function() current}) async {
    final previous = setup;
    if (previous == null) return;
    await _read(current, (api) => api.get(previous.id, previous: previous), (
      value,
    ) {
      setup = value;
      needsRefresh = false;
    });
  }

  Future<void> submit(
    ServerMusicProviderSetupSubmission submission, {
    required bool Function() current,
  }) => _mutate(
    current,
    (api, previous) => api.submit(previous: previous, submission: submission),
  );

  Future<void> resume({required bool Function() current}) =>
      _mutate(current, (api, previous) => api.resume(previous));

  Future<void> retry({required bool Function() current}) =>
      _mutate(current, (api, previous) => api.retry(previous));

  Future<void> cancel({required bool Function() current}) =>
      _mutate(current, (api, previous) => api.cancel(previous));

  Future<void> _read<T>(
    bool Function() current,
    Future<T> Function(ServerMusicProviderSetupApi api) action,
    void Function(T value) accept,
  ) => _run(current, (api, valid) async {
    final value = await action(api);
    if (valid()) accept(value);
  });

  Future<void> _mutate(
    bool Function() current,
    Future<ServerMusicProviderSetup> Function(
      ServerMusicProviderSetupApi api,
      ServerMusicProviderSetup previous,
    )
    action,
  ) async {
    final previous = setup;
    if (previous == null || needsRefresh) return;
    await _run(current, (api, valid) async {
      final value = await action(api, previous);
      if (valid()) setup = value;
    }, mutation: previous);
  }

  Future<void> _run(
    bool Function() current,
    Future<void> Function(
      ServerMusicProviderSetupApi api,
      bool Function() valid,
    )
    action, {
    ServerMusicProviderSetup? mutation,
    bool createMutation = false,
  }) async {
    if (_disposed || busy || !_authorized || !current()) return;
    final epoch = _epoch;
    bool valid() => _current(epoch, current);
    busy = true;
    failure = null;
    reconciled = false;
    _emit();
    try {
      await account.withSession((raw, session) async {
        if (!valid()) throw const LarenorServerException('cancelled');
        await action(
          ServerMusicProviderSetupApi(raw, session.accessToken),
          valid,
        );
      });
      if (valid()) {
        needsRefresh = false;
      } else if (!_disposed && epoch == _epoch && _authorized) {
        // The route may have lost foreground authority after a POST started.
        // Keep the result unusable until an authoritative read is possible.
        if (createMutation) {
          createOutcomeUnknown = true;
        } else if (mutation != null) {
          needsRefresh = true;
        }
      }
    } catch (error) {
      if (!valid()) return;
      final code = error is LarenorServerException
          ? error.code
          : 'connection_failed';
      failure = code;
      if (createMutation && _unknownOutcomeCodes.contains(code)) {
        // The create request ID is idempotent, but the public API has no
        // request-ID lookup. Do not issue a second POST from this route.
        createOutcomeUnknown = true;
      } else if (mutation != null && _readbackCodes.contains(code)) {
        await _reconcile(mutation, valid);
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> _reconcile(
    ServerMusicProviderSetup previous,
    bool Function() valid,
  ) async {
    try {
      await account.withSession((raw, session) async {
        final value = await ServerMusicProviderSetupApi(
          raw,
          session.accessToken,
        ).get(previous.id, previous: previous);
        if (!valid()) return;
        setup = value;
        needsRefresh = false;
        reconciled = value.revision > previous.revision;
        if (reconciled) failure = null;
      });
    } catch (_) {
      if (valid()) needsRefresh = true;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
