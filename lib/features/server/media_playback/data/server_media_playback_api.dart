import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../../media_catalog/domain/server_media_catalog_models.dart';
import '../domain/server_media_playback_models.dart';

final class ServerMediaPlaybackApi {
  ServerMediaPlaybackApi(
    this.api,
    this.token, {
    String Function()? requestId,
    DateTime Function()? now,
  }) : _requestId = requestId ?? _randomId,
       _now = now ?? DateTime.now;

  final LarenorServerApi api;
  final String token;
  final String Function() _requestId;
  final DateTime Function() _now;

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<ServerMediaPlaybackIntent> prepare(
    ServerMediaCatalogPage page,
    ServerMediaCatalogItem item,
  ) async {
    if (!page.items.any((candidate) => identical(candidate, item))) {
      throw const LarenorServerException('invalid_request');
    }
    final requestId = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const LarenorServerException('invalid_request');
    }
    try {
      final response = serverObject(
        await api.request(
          'POST',
          '/media/playback/intents',
          token: token,
          body: {
            'requestId': requestId,
            'installationId': page.installationId,
            'expectedInstallationRevision': page.installationRevision,
            'expectedSnapshotRevision': page.snapshotRevision,
            'expectedJellyfinServiceRevision': page.jellyfinServiceRevision,
            'itemId': item.itemId,
            'mediaKey': item.mediaKey,
          },
        ),
      );
      if (response.length != 1 || !response.containsKey('intent')) {
        throw const FormatException();
      }
      final intent = ServerMediaPlaybackIntent.fromJson(response['intent']);
      if (intent.id != requestId ||
          intent.installationId != page.installationId ||
          intent.installationRevision != page.installationRevision ||
          intent.snapshotRevision != page.snapshotRevision ||
          intent.jellyfinServiceRevision != page.jellyfinServiceRevision ||
          intent.itemId != item.itemId ||
          intent.mediaKey != item.mediaKey ||
          !_now().toUtc().isBefore(intent.expiresAt)) {
        throw const FormatException();
      }
      return intent;
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<ServerMediaPlaybackReceipt> play(
    ServerMediaPlaybackIntent intent,
    ServerMediaPlaybackTarget target, {
    int startSeconds = 0,
  }) async {
    if (!intent.targets.any((candidate) => identical(candidate, target)) ||
        !target.available ||
        startSeconds < 0 ||
        startSeconds > 8640000 ||
        !_now().toUtc().isBefore(intent.expiresAt)) {
      throw const LarenorServerException('invalid_request');
    }
    final requestId = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const LarenorServerException('invalid_request');
    }
    try {
      final response = serverObject(
        await api.request(
          'POST',
          '/media/playback/commands',
          token: token,
          body: {
            'requestId': requestId,
            'intentId': intent.id,
            'expectedPlaybackRevision': intent.playbackRevision,
            'targetId': target.id,
            'expectedTargetRevision': target.revision,
            'startSeconds': startSeconds,
          },
        ),
      );
      if (response.length != 1 || !response.containsKey('receipt')) {
        throw const FormatException();
      }
      return ServerMediaPlaybackReceipt.fromJson(
        response['receipt'],
        expectedRequestId: requestId,
        expectedIntentId: intent.id,
        expectedInstallationId: intent.installationId,
        expectedItemId: intent.itemId,
        expectedTargetId: target.id,
        expectedPlaybackRevision: intent.playbackRevision,
      );
    } on FormatException {
      throw const LarenorServerException('invalid_response');
    }
  }
}
