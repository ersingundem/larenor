import 'dart:async';

import '../../../ha_client/data/ha_api_exception.dart';
import '../../../ha_client/data/ws_client.dart';
import '../domain/ha_media_inventory.dart';
import '../domain/ha_playback_models.dart';

abstract class HaPlaybackApi {
  Stream<bool> get connectionChanges => Stream.value(true);
  Future<HaMediaInventory> getInventory();
  Future<HaMediaBrowsePage> browse(String? sourceId);
  Future<void> play({
    required String entityId,
    required HaMediaNode source,
    required bool Function() isCurrent,
  });
}

/// Uses HA's existing authenticated socket. Never resolves a source URL or
/// attaches HA/Jellyfin credentials to a receiver payload.
class WsHaPlaybackApi extends HaPlaybackApi {
  WsHaPlaybackApi(
    this.client, {
    DateTime Function()? now,
    bool Function()? isCurrent,
    int Function()? generation,
  }) : _now = now ?? DateTime.now,
       _isCurrent = isCurrent ?? (() => true),
       _generation = generation ?? (() => 0);
  final HaWebSocketClient client;
  @override
  Stream<bool> get connectionChanges => client.status
      .map((status) => status == HaConnectionStatus.connected)
      .distinct();
  final DateTime Function() _now;
  final bool Function() _isCurrent;
  final int Function() _generation;
  void _check([int? generation]) {
    if (!_isCurrent() || (generation != null && generation != _generation())) {
      throw const HaPlaybackException(HaPlaybackFailure.invalidIntent);
    }
  }

  @override
  Future<HaMediaInventory> getInventory() async {
    final generation = _generation();
    bool current() => _isCurrent() && generation == _generation();
    _check(generation);
    // Sequential bounded reads allow account/lifecycle cancellation between IO.
    final states = await client.sendCommand({
      'type': 'get_states',
    }, isCurrent: current);
    _check(generation);
    final services = await client.sendCommand({
      'type': 'get_services',
    }, isCurrent: current);
    _check(generation);
    Object? registry;
    HaPlaybackFailure? registryFailure;
    try {
      registry = await client.sendCommand({
        'type': 'config/entity_registry/list',
      }, isCurrent: current);
      if (registry == null) invalidHaMedia();
    } catch (error) {
      registryFailure = haPlaybackFailure(error);
      if (!{
        HaPlaybackFailure.permission,
        HaPlaybackFailure.unavailable,
      }.contains(registryFailure)) {
        rethrow;
      }
    }
    _check(generation);
    return parseHaMediaInventory(
      states: states,
      services: services,
      registry: registry,
      readAt: _now().toUtc(),
      registryFailure: registryFailure,
    );
  }

  @override
  Future<HaMediaBrowsePage> browse(String? sourceId) async {
    final generation = _generation();
    bool current() => _isCurrent() && generation == _generation();
    _check(generation);
    if (sourceId != null) haMediaSourceId(sourceId);
    final raw = await client.sendCommand({
      'type': 'media_source/browse_media',
      'media_content_id': ?sourceId,
    }, isCurrent: current);
    _check(generation);
    final page = parseHaMediaBrowse(raw, _now().toUtc());
    if (page.parent.id != (sourceId ?? 'media-source://')) invalidHaMedia();
    return page;
  }

  @override
  Future<void> play({
    required String entityId,
    required HaMediaNode source,
    required bool Function() isCurrent,
  }) async {
    final generation = _generation();
    _check(generation);
    if (!RegExp(r'^media_player\.[a-z0-9_]+$').hasMatch(entityId) ||
        !source.playable ||
        !RegExp(r'^(audio|video)/[a-zA-Z0-9!#&^_.+-]+$')
            .hasMatch(source.mediaType)) {
      throw const HaPlaybackException(HaPlaybackFailure.unsupportedSource);
    }
    haMediaSourceId(source.id, allowRoot: false);
    bool current() =>
        _isCurrent() && generation == _generation() && isCurrent();
    if (!current()) {
      throw const HaPlaybackException(HaPlaybackFailure.invalidIntent);
    }
    await client.callService(
      'media_player',
      'play_media',
      target: {'entity_id': entityId},
      serviceData: {
        'media_content_id': source.id,
        'media_content_type': source.mediaType,
      },
      isCurrent: current,
    );
  }
}

HaPlaybackFailure haPlaybackFailure(Object error) {
  if (error is HaPlaybackException) return error.failure;
  if (error is TimeoutException) return HaPlaybackFailure.timeout;
  if (error is HaApiException) {
    if (error.statusCode == 401 ||
        {'auth_invalid', 'invalid_auth'}.contains(error.code)) {
      return HaPlaybackFailure.authentication;
    }
    if (error.statusCode == 403 ||
        {
          'forbidden',
          'unauthorized',
          'unauthorized_user',
          'permission_denied',
        }.contains(error.code)) {
      return HaPlaybackFailure.permission;
    }
    if (error.code == 'timeout') return HaPlaybackFailure.timeout;
    if (error.code == 'cancelled') return HaPlaybackFailure.invalidIntent;
    if ({
      'not_supported',
      'unknown_command',
      'entity_not_found',
      'service_not_found',
    }.contains(error.code)) {
      return HaPlaybackFailure.unavailable;
    }
    return HaPlaybackFailure.transport;
  }
  if (error is FormatException || error is TypeError) {
    return HaPlaybackFailure.invalidResponse;
  }
  return HaPlaybackFailure.transport;
}
