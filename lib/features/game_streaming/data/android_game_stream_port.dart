import 'package:flutter/services.dart';

import '../domain/game_stream_session.dart';

final class AndroidGameStreamCredentialHandle {
  AndroidGameStreamCredentialHandle(this.id) {
    if (!_identity.hasMatch(id)) {
      throw ArgumentError('invalid_credential_handle');
    }
  }

  final String id;

  @override
  String toString() => 'AndroidGameStreamCredentialHandle(<redacted>)';
}

final class AndroidGameStreamBinding {
  AndroidGameStreamBinding({
    required this.sessionId,
    required this.epoch,
    required this.accountRevision,
    required this.routeRevision,
    required this.lifecycleRevision,
    required this.idleRevision,
    required this.interactionRevision,
    required this.credentialHandle,
  }) {
    _requireIdentity(sessionId);
    for (final value in [
      epoch,
      accountRevision,
      routeRevision,
      lifecycleRevision,
      idleRevision,
      interactionRevision,
    ]) {
      _requireRevision(value);
    }
  }

  final String sessionId;
  final int epoch;
  final int accountRevision;
  final int routeRevision;
  final int lifecycleRevision;
  final int idleRevision;
  final int interactionRevision;
  final AndroidGameStreamCredentialHandle credentialHandle;

  Map<String, Object> toChannel() => {
    'sessionId': sessionId,
    'epoch': epoch,
    'accountRevision': accountRevision,
    'routeRevision': routeRevision,
    'lifecycleRevision': lifecycleRevision,
    'idleRevision': idleRevision,
    'interactionRevision': interactionRevision,
    'credentialHandle': credentialHandle.id,
  };

  bool sameAuthority(AndroidGameStreamBinding other) =>
      sessionId == other.sessionId &&
      epoch == other.epoch &&
      accountRevision == other.accountRevision &&
      routeRevision == other.routeRevision &&
      lifecycleRevision == other.lifecycleRevision &&
      idleRevision == other.idleRevision &&
      interactionRevision == other.interactionRevision &&
      identical(credentialHandle, other.credentialHandle);

  @override
  String toString() => 'AndroidGameStreamBinding(<redacted>)';
}

final class AndroidGameStreamCapabilities {
  const AndroidGameStreamCapabilities({
    required this.available,
    required this.engineRevision,
    required this.intents,
  });

  final bool available;
  final String? engineRevision;
  final Set<GameStreamIntent> intents;
}

abstract interface class GameStreamNativeBindingPort {
  Future<void> bind(AndroidGameStreamBinding binding);

  Future<void> retireBinding(AndroidGameStreamBinding binding);

  Future<void> retire(GameStreamRetirement retirement);
}

abstract interface class GameStreamCapabilityPort {
  Future<AndroidGameStreamCapabilities> capabilities();
}

/// Fail-closed Android port. The default native implementation advertises an
/// unavailable engine until a reviewed Moonlight/Sunshine runtime is packaged.
final class AndroidGameStreamPort
    implements
        GameStreamPort,
        GameStreamNativeBindingPort,
        GameStreamCapabilityPort {
  AndroidGameStreamPort({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.ersingundem.larenor/game-stream-native';

  final MethodChannel _channel;
  AndroidGameStreamBinding? _binding;
  int _generation = 0;

  @override
  Future<AndroidGameStreamCapabilities> capabilities() async {
    final raw = await _channel.invokeMethod<Object?>('capabilities');
    final value = _strictMap(raw, {
      'schemaVersion',
      'availability',
      'engineRevision',
      'intents',
      'maxInflight',
    });
    if (value['schemaVersion'] != 1 || value['maxInflight'] != 1) {
      throw const GameStreamException('invalid_capabilities');
    }
    final availability = value['availability'];
    final rawEngineRevision = value['engineRevision'];
    final rawIntents = value['intents'];
    if ((availability != 'available' && availability != 'unavailable') ||
        (rawEngineRevision != null && rawEngineRevision is! String) ||
        rawIntents is! List ||
        rawIntents.length > GameStreamIntent.values.length) {
      throw const GameStreamException('invalid_capabilities');
    }
    final intents = <GameStreamIntent>{};
    for (final rawIntent in rawIntents) {
      final parsed = _intent(rawIntent, 'invalid_capabilities');
      if (!intents.add(parsed)) {
        throw const GameStreamException('invalid_capabilities');
      }
    }
    final engineRevision = rawEngineRevision as String?;
    if (availability == 'unavailable' &&
        (engineRevision != null || intents.isNotEmpty)) {
      throw const GameStreamException('invalid_capabilities');
    }
    if (availability == 'available' &&
        (engineRevision == null ||
            !_engineRevision.hasMatch(engineRevision) ||
            intents.isEmpty)) {
      throw const GameStreamException('invalid_capabilities');
    }
    return AndroidGameStreamCapabilities(
      available: availability == 'available',
      engineRevision: engineRevision,
      intents: Set.unmodifiable(intents),
    );
  }

  @override
  Future<void> bind(AndroidGameStreamBinding binding) async {
    final current = _binding;
    if (current != null && current.sameAuthority(binding)) return;
    final generation = ++_generation;
    _binding = null;
    if (current != null) {
      await _retireNative(current);
      if (_generation != generation) {
        throw const GameStreamException('stale_native_callback');
      }
    }
    await _channel.invokeMethod<void>('bind', binding.toChannel());
    if (_generation != generation) {
      await _retireNative(binding, bestEffort: true);
      throw const GameStreamException('stale_native_callback');
    }
    _binding = binding;
  }

  @override
  Future<GameStreamNativeReceipt> execute(
    GameStreamCommand command,
    Object credentialHandle,
  ) async {
    final binding = _binding;
    final generation = _generation;
    if (binding == null ||
        binding.sessionId != command.sessionId ||
        !identical(binding.credentialHandle, credentialHandle)) {
      throw const GameStreamException('stale_native_binding');
    }
    final raw = await _channel.invokeMethod<Object?>('execute', {
      'sessionId': binding.sessionId,
      'epoch': binding.epoch,
      'command': command.toJson(),
    });
    if (_binding != binding || _generation != generation) {
      throw const GameStreamException('stale_native_callback');
    }
    return _receipt(raw, command);
  }

  @override
  Future<void> retire(GameStreamRetirement retirement) async {
    final binding = _binding;
    if (binding == null) return;
    if (binding.sessionId != retirement.sessionId) {
      throw const GameStreamException('stale_native_binding');
    }
    await retireBinding(binding);
  }

  @override
  Future<void> retireBinding(AndroidGameStreamBinding binding) async {
    final current = _binding;
    if (current == null || !identical(current, binding)) {
      throw const GameStreamException('stale_native_binding');
    }
    _generation += 1;
    _binding = null;
    await _retireNative(binding);
  }

  Future<void> _retireNative(
    AndroidGameStreamBinding binding, {
    bool bestEffort = false,
  }) async {
    try {
      await _channel.invokeMethod<void>('retire', {
        'sessionId': binding.sessionId,
        'epoch': binding.epoch,
      });
    } catch (_) {
      if (!bestEffort) rethrow;
    }
  }

  GameStreamNativeReceipt _receipt(Object? raw, GameStreamCommand command) {
    final value = _strictMap(raw, {
      'sessionId',
      'commandId',
      'requestId',
      'intent',
      'revisions',
      'quality',
      'accepted',
      'observedState',
      'readbackRevision',
    });
    final revisions = _strictMap(
      value['revisions'],
      command.revisions.toJson().keys.toSet(),
    );
    final quality = _strictMap(
      value['quality'],
      command.quality.toJson().keys.toSet(),
    );
    if (value['sessionId'] != command.sessionId ||
        value['commandId'] != command.commandId ||
        value['requestId'] != command.requestId ||
        _intent(value['intent'], 'invalid_native_receipt') != command.intent ||
        !_sameMap(revisions, command.revisions.toJson()) ||
        !_sameMap(quality, command.quality.toJson()) ||
        value['accepted'] is! bool) {
      throw const GameStreamException('invalid_native_receipt');
    }
    final state = NativeStreamState.values.where(
      (candidate) => candidate.name == value['observedState'],
    );
    final readbackRevision = value['readbackRevision'];
    if (state.length != 1 || readbackRevision is! int) {
      throw const GameStreamException('invalid_native_receipt');
    }
    _requireRevision(readbackRevision);
    return GameStreamNativeReceipt(
      sessionId: command.sessionId,
      commandId: command.commandId,
      requestId: command.requestId,
      intent: command.intent,
      revisions: command.revisions,
      quality: command.quality,
      accepted: value['accepted']! as bool,
      observedState: state.single,
      readbackRevision: readbackRevision,
    );
  }
}

Map<Object?, Object?> _strictMap(Object? raw, Set<String> keys) {
  if (raw is! Map || raw.keys.any((key) => key is! String)) {
    throw const GameStreamException('invalid_native_payload');
  }
  final value = Map<Object?, Object?>.from(raw);
  if (value.keys.toSet().length != keys.length ||
      !value.keys.toSet().containsAll(keys)) {
    throw const GameStreamException('invalid_native_payload');
  }
  return value;
}

GameStreamIntent _intent(Object? raw, String code) {
  final matches = GameStreamIntent.values.where((value) => value.name == raw);
  if (matches.length != 1) throw GameStreamException(code);
  return matches.single;
}

bool _sameMap(Map<Object?, Object?> left, Map<String, Object> right) =>
    left.length == right.length &&
    right.entries.every((entry) => left[entry.key] == entry.value);

void _requireIdentity(String value) {
  if (!_identity.hasMatch(value)) throw ArgumentError('invalid_identity');
}

void _requireRevision(int value) {
  if (value < 1 || value > 9223372036854775806) {
    throw ArgumentError('invalid_revision');
  }
}

final _identity = RegExp(r'^[0-9a-f]{32}$');
final _engineRevision = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
