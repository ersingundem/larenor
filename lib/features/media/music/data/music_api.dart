import 'dart:async';
import 'dart:io';

import '../../ha_playback/domain/ha_playback_models.dart';
import '../../../ha_client/data/ha_api_exception.dart';
import '../../../ha_client/data/ws_client.dart';
import '../domain/music_models.dart';
import 'music_parser.dart';

abstract interface class MusicAssistantApi {
  Future<Object?> configEntries({required bool Function() isCurrent});
  Future<Object?> library(
    MusicLibraryQuery query, {
    required bool Function() isCurrent,
  });
  Future<Object?> search(
    MusicSearchQuery query, {
    required bool Function() isCurrent,
  });
  Future<Object?> queue(String entityId, {required bool Function() isCurrent});
}

/// Only HA's documented read-only response services are exposed. The underlying
/// WebSocket waits for connection once and rechecks the account before sending.
class WsMusicAssistantApi implements MusicAssistantApi {
  const WsMusicAssistantApi(this.ws);
  final HaWebSocketClient ws;
  @override
  Future<Object?> configEntries({required bool Function() isCurrent}) =>
      ws.sendCommand({
        'type': 'config_entries/get',
        'domain': 'music_assistant',
      }, isCurrent: isCurrent);
  Future<Object?> _read(
    String service,
    Map<String, dynamic> data,
    bool Function() current, {
    Map<String, dynamic>? target,
  }) async {
    final raw = await ws.callService(
      'music_assistant',
      service,
      serviceData: data,
      target: target,
      returnResponse: true,
      isCurrent: current,
    );
    validateMusicPayload(raw);
    final envelope = musicObject(raw);
    if (!envelope.containsKey('response')) {
      throw const MusicException(MusicFailure.invalidResponse);
    }
    return envelope['response'];
  }

  @override
  Future<Object?> library(
    MusicLibraryQuery query, {
    required bool Function() isCurrent,
  }) => _read('get_library', {
    'config_entry_id': query.configEntryId,
    'media_type': query.type.name,
    'limit': query.limit,
    'offset': query.offset,
    if (query.favorite != null) 'favorite': query.favorite,
  }, isCurrent);
  @override
  Future<Object?> search(
    MusicSearchQuery query, {
    required bool Function() isCurrent,
  }) => _read('search', {
    'config_entry_id': query.configEntryId,
    'name': query.text.trim(),
    'limit': query.limit,
    'library_only': query.libraryOnly,
    if (query.types.isNotEmpty)
      'media_type': query.types.map((t) => t.name).toList(),
  }, isCurrent);
  @override
  Future<Object?> queue(
    String entityId, {
    required bool Function() isCurrent,
  }) => _read(
    'get_queue',
    {},
    isCurrent,
    target: {
      'entity_id': [entityId],
    },
  );
}

MusicFailure classifyMusicFailure(Object error) {
  if (error is MusicException) return error.failure;
  if (error is TimeoutException) return MusicFailure.timeout;
  if (error is SocketException || error is HttpException) {
    return MusicFailure.transport;
  }
  if (error is HaPlaybackException) {
    return switch (error.failure) {
      HaPlaybackFailure.authentication => MusicFailure.authentication,
      HaPlaybackFailure.permission => MusicFailure.permission,
      HaPlaybackFailure.transport => MusicFailure.transport,
      HaPlaybackFailure.timeout => MusicFailure.timeout,
      HaPlaybackFailure.invalidResponse => MusicFailure.invalidResponse,
      _ => MusicFailure.unavailable,
    };
  }
  if (error is HaApiException) {
    if (error.statusCode == 401 || error.code == 'auth_invalid') {
      return MusicFailure.authentication;
    }
    // WS unauthorized reflects a denied command, not a rejected login token.
    if (error.statusCode == 403 ||
        {'unauthorized', 'forbidden'}.contains(error.code)) {
      return MusicFailure.permission;
    }
    if (error.code == 'timeout') return MusicFailure.timeout;
    if (error.code == 'cancelled') return MusicFailure.stale;
    if ({'connection_error', 'closed', 'not_connected'}.contains(error.code)) {
      return MusicFailure.transport;
    }
    if ({
      'not_found',
      'unknown_command',
      'service_not_found',
    }.contains(error.code)) {
      return MusicFailure.unsupported;
    }
    if (error.code == 'home_assistant_error' ||
        (error.statusCode ?? 0) >= 500) {
      return MusicFailure.unavailable;
    }
  }
  return MusicFailure.invalidResponse;
}

/// Adds a route/intent generation to an existing read adapter. Rechecks both
/// after connection wait (through the callback) and after the result arrives.
class ScopedMusicAssistantApi implements MusicAssistantApi {
  const ScopedMusicAssistantApi(
    this.delegate, {
    required this.isActive,
    required this.generation,
  });
  final MusicAssistantApi delegate;
  final bool Function() isActive;
  final int Function() generation;
  Future<Object?> _read(
    Future<Object?> Function(bool Function()) request,
    bool Function() callerCurrent,
  ) async {
    final epoch = generation();
    bool current() => isActive() && callerCurrent() && epoch == generation();
    if (!current()) throw const MusicException(MusicFailure.stale);
    final result = await request(current);
    if (!current()) throw const MusicException(MusicFailure.stale);
    return result;
  }

  @override
  Future<Object?> configEntries({required bool Function() isCurrent}) =>
      _read((current) => delegate.configEntries(isCurrent: current), isCurrent);
  @override
  Future<Object?> library(
    MusicLibraryQuery query, {
    required bool Function() isCurrent,
  }) => _read(
    (current) => delegate.library(query, isCurrent: current),
    isCurrent,
  );
  @override
  Future<Object?> search(
    MusicSearchQuery query, {
    required bool Function() isCurrent,
  }) =>
      _read((current) => delegate.search(query, isCurrent: current), isCurrent);
  @override
  Future<Object?> queue(
    String entityId, {
    required bool Function() isCurrent,
  }) => _read(
    (current) => delegate.queue(entityId, isCurrent: current),
    isCurrent,
  );
}
