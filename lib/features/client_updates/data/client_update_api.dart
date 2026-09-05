import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/client_update_models.dart';

abstract class ClientUpdateApi {
  Future<InstalledClientSnapshot> snapshot();
  Stream<ClientUpdateProgress> get progress;
  Future<void> activateSession(String sessionId);
  Future<StagedClientUpdate> download({
    required String sessionId,
    required String downloadId,
    required String baseUrl,
    required String accessToken,
    required ClientRelease release,
    required int interactionEpoch,
  });
  Future<void> cancel(String sessionId);
  Future<void> invalidate(String sessionId);
  Future<ClientInstallOutcome> install(
    String sessionId,
    StagedClientUpdate staged, {
    required int interactionEpoch,
  });
  Future<void> openInstallPermission(
    String sessionId, {
    required int interactionEpoch,
  });
}

class AndroidClientUpdateApi extends ClientUpdateApi {
  AndroidClientUpdateApi({
    MethodChannel? methods,
    EventChannel? events,
    bool? isAndroid,
  }) : _methods =
           methods ??
           const MethodChannel('com.ersingundem.larenor/client_updates'),
       _events =
           events ??
           const EventChannel('com.ersingundem.larenor/client_updates_events'),
       _android =
           isAndroid ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  final MethodChannel _methods;
  final EventChannel _events;
  final bool _android;
  Future<Object?> _call(
    String method, [
    Object? arguments,
    Duration timeout = const Duration(seconds: 15),
  ]) async {
    if (!_android) {
      throw const ClientUpdateException(ClientUpdateFailure.unsupported);
    }
    try {
      return await _methods
          .invokeMethod<Object?>(method, arguments)
          .timeout(timeout);
    } on PlatformException catch (e) {
      throw ClientUpdateException(
        ClientUpdateFailure.values.where((v) => v.name == e.code).firstOrNull ??
            ClientUpdateFailure.unavailable,
      );
    } on MissingPluginException {
      throw const ClientUpdateException(ClientUpdateFailure.unsupported);
    } on TimeoutException {
      throw const ClientUpdateException(ClientUpdateFailure.unavailable);
    }
  }

  @override
  Future<InstalledClientSnapshot> snapshot() async => !_android
      ? const InstalledClientSnapshot.unsupported()
      : InstalledClientSnapshot.fromChannel(await _call('snapshot'));
  @override
  late final Stream<ClientUpdateProgress> progress = !_android
      ? const Stream.empty()
      : _events.receiveBroadcastStream().map(ClientUpdateProgress.fromChannel);
  @override
  Future<void> activateSession(String sessionId) async {
    await _call('activateSession', {'sessionId': sessionId});
  }

  @override
  Future<StagedClientUpdate> download({
    required String sessionId,
    required String downloadId,
    required String baseUrl,
    required String accessToken,
    required ClientRelease release,
    required int interactionEpoch,
  }) async => StagedClientUpdate.fromChannel(
    await _call('download', {
      'sessionId': sessionId,
      'downloadId': downloadId,
      'baseUrl': baseUrl,
      'accessToken': accessToken,
      'release': release.toJson(),
      'interactionEpoch': interactionEpoch,
    }, const Duration(minutes: 11)),
  );
  @override
  Future<void> cancel(String sessionId) async {
    await _call('cancel', {'sessionId': sessionId});
  }

  @override
  Future<void> invalidate(String sessionId) async {
    await _call('invalidate', {'sessionId': sessionId});
  }

  @override
  Future<ClientInstallOutcome> install(
    String sessionId,
    StagedClientUpdate staged, {
    required int interactionEpoch,
  }) async {
    final raw = await _call('install', {
      'sessionId': sessionId,
      'id': staged.id,
      'interactionEpoch': interactionEpoch,
    }, const Duration(minutes: 2));
    if (raw is! Map ||
        raw.length != 1 ||
        raw['outcome'] != 'systemPromptOpened') {
      throw const ClientUpdateException(ClientUpdateFailure.unavailable);
    }
    return ClientInstallOutcome.systemPromptOpened;
  }

  @override
  Future<void> openInstallPermission(
    String sessionId, {
    required int interactionEpoch,
  }) async {
    await _call('openInstallPermission', {
      'sessionId': sessionId,
      'interactionEpoch': interactionEpoch,
    });
  }
}
