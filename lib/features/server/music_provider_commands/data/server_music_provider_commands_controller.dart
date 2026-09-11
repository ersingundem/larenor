import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_provider_command_models.dart';
import 'server_music_provider_commands_api.dart';

/// Route-owned preview authority. It never confirms without a second user action.
class ServerMusicProviderCommandsController extends ChangeNotifier {
  ServerMusicProviderCommandsController(
    this.account, {
    required this.installationId,
    required this.installationRevision,
    required this.providerSetupId,
    required this.providerRevision,
    required this.providerDomain,
    String Function()? requestId,
  }) : _accountEpoch = account.generation,
       _requestId = requestId ?? _randomId {
    account.addListener(_accountChanged);
  }
  final ServerAccountController account;
  final String installationId, providerSetupId, providerDomain;
  final int installationRevision, providerRevision, _accountEpoch;
  final String Function() _requestId;
  int _epoch = 0;
  bool _disposed = false;
  bool busy = false;
  String? failure;
  ServerMusicProviderCommandPreview? preview;
  ServerMusicProviderCommand? command;

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
  void _accountChanged() {
    if (!_authorized) invalidate();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void invalidate() {
    _epoch++;
    busy = false;
    failure = null;
    preview = null;
    command = null;
    _emit();
  }

  Future<void> review(
    String requestedCommand, {
    required bool Function() current,
  }) async {
    if (busy || !_authorized || !current()) return;
    final epoch = _epoch;
    bool valid() => !_disposed && epoch == _epoch && _authorized && current();
    busy = true;
    failure = null;
    preview = null;
    command = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        final intent = ServerMusicProviderCommandIntent(
          installationId: installationId,
          installationRevision: installationRevision,
          providerSetupId: providerSetupId,
          providerRevision: providerRevision,
          providerDomain: providerDomain,
          command: requestedCommand,
          requestId: _requestId(),
        );
        final value = await ServerMusicProviderCommandsApi(
          api,
          session.accessToken,
        ).preview(intent);
        if (valid()) {
          preview = value;
        }
      });
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
    }
  }

  Future<void> confirm({required bool Function() current}) async {
    final reviewed = preview;
    if (reviewed == null ||
        busy ||
        command != null ||
        !_authorized ||
        !current()) {
      return;
    }
    final epoch = _epoch;
    bool valid() =>
        !_disposed &&
        epoch == _epoch &&
        _authorized &&
        current() &&
        identical(preview, reviewed);
    busy = true;
    failure = null;
    _emit();
    try {
      await account.withSession((api, session) async {
        final value = await ServerMusicProviderCommandsApi(
          api,
          session.accessToken,
        ).confirm(preview: reviewed, requestId: _requestId());
        if (valid()) {
          command = value;
        }
      });
    } catch (error) {
      if (valid()) {
        failure = error is LarenorServerException
            ? error.code
            : 'connection_failed';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        busy = false;
        _emit();
      }
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
