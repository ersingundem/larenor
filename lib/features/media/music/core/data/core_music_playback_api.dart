import 'dart:math';

import '../../../../server/data/larenor_server_api.dart';
import '../../../../server/data/server_account_controller.dart';
import '../../../../server/domain/server_models.dart';
import '../domain/core_music_playback_models.dart';
import '../domain/core_music_target_models.dart';

abstract interface class CoreMusicPlaybackApi {
  Future<CoreMusicPlaybackReceipt> execute({
    required CoreMusicTargetInventory inventory,
    required CoreMusicTarget target,
    required CoreMusicPlaybackOperation operation,
    int? volumeLevel,
    int? seekPosition,
    required bool Function() isCurrent,
  });
}

class AccountCoreMusicPlaybackApi implements CoreMusicPlaybackApi {
  AccountCoreMusicPlaybackApi(this.account) : generation = account.generation;

  final ServerAccountController account;
  final int generation;

  bool get authorized =>
      account.isCurrent(generation) &&
      account.initialized &&
      !account.working &&
      account.session?.user.canAdminister == true;

  @override
  Future<CoreMusicPlaybackReceipt> execute({
    required CoreMusicTargetInventory inventory,
    required CoreMusicTarget target,
    required CoreMusicPlaybackOperation operation,
    int? volumeLevel,
    int? seekPosition,
    required bool Function() isCurrent,
  }) async {
    bool current() => authorized && isCurrent();
    if (!current()) throw const LarenorServerException('forbidden');
    return account.withSession((transport, session) {
      if (!current() || !session.user.canAdminister) {
        throw const LarenorServerException('cancelled');
      }
      return ServerCoreMusicPlaybackApi(transport, session.accessToken).execute(
        inventory: inventory,
        target: target,
        operation: operation,
        volumeLevel: volumeLevel,
        seekPosition: seekPosition,
        isCurrent: current,
      );
    });
  }
}

class ServerCoreMusicPlaybackApi implements CoreMusicPlaybackApi {
  ServerCoreMusicPlaybackApi(
    this.transport,
    this.accessToken, {
    String Function()? requestId,
  }) : _requestId = requestId ?? _secureRequestId;

  final LarenorServerApi transport;
  final String accessToken;
  final String Function() _requestId;

  @override
  Future<CoreMusicPlaybackReceipt> execute({
    required CoreMusicTargetInventory inventory,
    required CoreMusicTarget target,
    required CoreMusicPlaybackOperation operation,
    int? volumeLevel,
    int? seekPosition,
    required bool Function() isCurrent,
  }) async {
    try {
      if (!isCurrent() ||
          !inventory.targets.any((item) => identical(item, target)) ||
          !target.available ||
          !target.enabled ||
          !target.capabilities.contains(operation.capability) ||
          (operation == CoreMusicPlaybackOperation.volume) !=
              (volumeLevel != null) ||
          (operation == CoreMusicPlaybackOperation.seek) !=
              (seekPosition != null) ||
          (volumeLevel != null && (volumeLevel < 0 || volumeLevel > 100)) ||
          (seekPosition != null &&
              (seekPosition < 0 || seekPosition > 604800))) {
        throw const LarenorServerException('invalid_request');
      }
      final requestId = _requestId();
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
        throw const LarenorServerException('invalid_request');
      }
      final response = await transport.request(
        'POST',
        '/admin/media/music-assistant/playback/commands',
        token: accessToken,
        body: {
          'requestId': requestId,
          'installationId': inventory.installationId,
          'expectedInstallationRevision': inventory.installationRevision,
          'expectedCoreRevision': inventory.coreRevision,
          'expectedPlayerRevision': inventory.playerRevision,
          'targetId': target.id,
          'expectedProvider': target.providerInstanceId,
          'expectedTargetKind': _targetKind(target),
          'expectedQueueId': target.queueId,
          'expectedGroupMembers': target.groupMemberIds,
          'operation': operation.wire,
          'volumeLevel': volumeLevel,
          'muted': null,
          'seekPosition': seekPosition,
          'mediaUris': <String>[],
        },
      );
      if (!isCurrent()) throw const LarenorServerException('cancelled');
      final envelope = _exact(response, const {'receipt'});
      final json = _exact(envelope['receipt'], const {
        'requestId',
        'targetId',
        'operation',
        'state',
        'playerRevision',
        'code',
        'installAvailable',
      });
      final state = switch (json['state']) {
        'succeeded' => CoreMusicReceiptState.succeeded,
        'needs_attention' => CoreMusicReceiptState.needsAttention,
        _ => throw const LarenorServerException('invalid_response'),
      };
      final expectedCode = state == CoreMusicReceiptState.succeeded
          ? 'authenticated_readback'
          : 'effect_unknown';
      final revision = json['playerRevision'];
      if (json['requestId'] != requestId ||
          json['targetId'] != target.id ||
          json['operation'] != operation.wire ||
          json['code'] != expectedCode ||
          json['installAvailable'] != false ||
          revision is! int ||
          revision <= inventory.playerRevision ||
          revision > 0x7fffffffffffffff) {
        throw const LarenorServerException('invalid_response');
      }
      return CoreMusicPlaybackReceipt(
        requestId: requestId,
        targetId: target.id,
        operation: operation,
        state: state,
        playerRevision: revision,
      );
    } on LarenorServerException {
      rethrow;
    } catch (_) {
      throw const LarenorServerException('invalid_response');
    }
  }

  static String _targetKind(CoreMusicTarget target) {
    if (target.homePod) return 'homepod';
    return switch ((target.transport, target.kind)) {
      (CoreMusicTransport.airplay, CoreMusicTargetKind.device) => 'airplay',
      (CoreMusicTransport.airplay, CoreMusicTargetKind.group) =>
        'airplay_group',
      (CoreMusicTransport.chromecast, CoreMusicTargetKind.device) =>
        'chromecast',
      (CoreMusicTransport.chromecast, CoreMusicTargetKind.group) =>
        'chromecast_group',
    };
  }

  static Map<String, dynamic> _exact(Object? value, Set<String> keys) {
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !value.keys.every(keys.contains)) {
      throw const LarenorServerException('invalid_response');
    }
    return value;
  }

  static String _secureRequestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
