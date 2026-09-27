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
  String? _createRequestId;
  ServerMusicProviderDomain? _createDomain;

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
    _createRequestId = null;
    _createDomain = null;
    _emit();
  }

  Future<void> loadCapabilities({required bool Function() current}) async {
    await _run(current, (api, valid) async {
      final available = await api.capabilities();
      final active = await api.active(
        installationId: installationId,
        installationRevision: installationRevision,
      );
      if (!valid()) return;
      capabilities = available;
      if (setup == null && active != null) {
        setup = active;
        _createRequestId = active.requestId;
        _createDomain = active.domain;
        createOutcomeUnknown = false;
      }
    });
  }

  Future<void> create(
    ServerMusicProviderDomain domain, {
    required bool Function() current,
  }) async {
    if (!canCreate || !_authorized || !current()) return;
    final requestId = _requestId();
    _createRequestId = requestId;
    _createDomain = domain;
    final intent = ServerMusicProviderSetupIntent(
      requestId: requestId,
      installationId: installationId,
      installationRevision: installationRevision,
      domain: domain,
    );
    await _run(current, (api, valid) async {
      final value = await api.create(intent);
      if (valid()) {
        setup = value;
        createOutcomeUnknown = false;
      }
    }, createMutation: true);
  }

  Future<void> refresh({required bool Function() current}) async {
    final previous = setup;
    if (previous == null) {
      if (_createRequestId != null) await _readCreate(current);
      return;
    }
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
        createOutcomeUnknown = true;
        await _reconcileCreate(valid);
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

  Future<void> _readCreate(bool Function() current) async {
    await _read(current, (api) => _createReadback(api), (value) {
      setup = value;
      createOutcomeUnknown = false;
      reconciled = true;
    });
  }

  Future<ServerMusicProviderSetup> _createReadback(
    ServerMusicProviderSetupApi api,
  ) async {
    final requestId = _createRequestId;
    final domain = _createDomain;
    if (requestId == null || domain == null) {
      throw const LarenorServerException('invalid_request');
    }
    final value = await api.getByRequest(
      installationId: installationId,
      installationRevision: installationRevision,
      requestId: requestId,
    );
    if (value.domain != domain) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  Future<void> _reconcileCreate(bool Function() valid) async {
    try {
      await account.withSession((raw, session) async {
        final value = await _createReadback(
          ServerMusicProviderSetupApi(raw, session.accessToken),
        );
        if (!valid()) return;
        setup = value;
        createOutcomeUnknown = false;
        reconciled = true;
        failure = null;
      });
    } catch (_) {
      // The exact request may not be visible yet. Keep create locked and let
      // the user repeat this GET readback; never repeat the POST.
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
