// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

enum HostPowerState { asleep, awake, unknown }

enum GameVideoCodec { h264, hevc, av1 }

enum NetworkReachability { local, remote, unavailable }

enum GameStreamIntent { wake, launch, stream, stop }

enum NativeStreamState { hostAwake, appRunning, streaming, stopped, rejected }

enum GameStreamPhase {
  created,
  ready,
  launched,
  streaming,
  stopped,
  rejected,
  outcomeUnknown,
  retired,
}

enum GameStreamReceiptStatus { verified, rejected, unknown }

enum GameStreamRetirementReason {
  authorityChanged,
  displayDetached,
  snapshotChanged,
  sessionExpired,
  explicit,
}

final class GameStreamException implements Exception {
  const GameStreamException(this.code);

  final String code;

  @override
  String toString() => 'GameStreamException($code)';
}

final class GameStreamAuthority {
  GameStreamAuthority({
    required this.accountId,
    required this.accountRevision,
    required this.pinRevision,
    required this.routeRevision,
    required this.lifecycleRevision,
    required this.idleRevision,
    required this.interactionRevision,
    required this.pinUnlocked,
    required this.foreground,
    required this.routeVisible,
    required this.interactionActive,
    required this.idle,
    this.idleFor = Duration.zero,
  }) {
    _requireId(accountId);
    for (final value in [
      accountRevision,
      pinRevision,
      routeRevision,
      lifecycleRevision,
      idleRevision,
      interactionRevision,
    ]) {
      _requireRevision(value);
    }
    if (idleFor.isNegative || idleFor > const Duration(days: 365)) {
      throw ArgumentError('invalid_idle_duration');
    }
  }

  final String accountId;
  final int accountRevision;
  final int pinRevision;
  final int routeRevision;
  final int lifecycleRevision;
  final int idleRevision;
  final int interactionRevision;
  final bool pinUnlocked;
  final bool foreground;
  final bool routeVisible;
  final bool interactionActive;
  final bool idle;
  final Duration idleFor;

  @override
  bool operator ==(Object other) =>
      other is GameStreamAuthority &&
      accountId == other.accountId &&
      accountRevision == other.accountRevision &&
      pinRevision == other.pinRevision &&
      routeRevision == other.routeRevision &&
      lifecycleRevision == other.lifecycleRevision &&
      idleRevision == other.idleRevision &&
      interactionRevision == other.interactionRevision &&
      pinUnlocked == other.pinUnlocked &&
      foreground == other.foreground &&
      routeVisible == other.routeVisible &&
      interactionActive == other.interactionActive &&
      idle == other.idle &&
      idleFor == other.idleFor;

  @override
  int get hashCode => Object.hash(
    accountId,
    accountRevision,
    pinRevision,
    routeRevision,
    lifecycleRevision,
    idleRevision,
    interactionRevision,
    pinUnlocked,
    foreground,
    routeVisible,
    interactionActive,
    idle,
    idleFor,
  );

  @override
  String toString() => 'GameStreamAuthority(redacted)';
}

final class GameStreamHost {
  GameStreamHost({
    required this.hostId,
    required this.hostRevision,
    required this.pairingRevision,
    required this.paired,
    required this.powerState,
  }) {
    _requireId(hostId);
    _requireRevision(hostRevision);
    _requireRevision(pairingRevision);
  }

  final String hostId;
  final int hostRevision;
  final int pairingRevision;
  final bool paired;
  final HostPowerState powerState;

  @override
  bool operator ==(Object other) =>
      other is GameStreamHost &&
      hostId == other.hostId &&
      hostRevision == other.hostRevision &&
      pairingRevision == other.pairingRevision &&
      paired == other.paired &&
      powerState == other.powerState;

  @override
  int get hashCode =>
      Object.hash(hostId, hostRevision, pairingRevision, paired, powerState);
}

final class GameStreamApp {
  GameStreamApp({
    required this.appId,
    required this.appRevision,
    required this.hostId,
    required this.hostRevision,
    required this.launchable,
  }) {
    _requireId(appId);
    _requireId(hostId);
    _requireRevision(appRevision);
    _requireRevision(hostRevision);
  }

  final String appId;
  final int appRevision;
  final String hostId;
  final int hostRevision;
  final bool launchable;

  @override
  bool operator ==(Object other) =>
      other is GameStreamApp &&
      appId == other.appId &&
      appRevision == other.appRevision &&
      hostId == other.hostId &&
      hostRevision == other.hostRevision &&
      launchable == other.launchable;

  @override
  int get hashCode =>
      Object.hash(appId, appRevision, hostId, hostRevision, launchable);
}

final class GameStreamDisplay {
  GameStreamDisplay({
    required this.displayId,
    required this.displayRevision,
    required this.attached,
    required this.widthPixels,
    required this.heightPixels,
    required this.densityDpi,
    required this.secureSurface,
  }) {
    if (displayId < 0 || displayId > 63) {
      throw ArgumentError('invalid_display');
    }
    _requireRevision(displayRevision);
    if (widthPixels < 320 ||
        widthPixels > 8192 ||
        heightPixels < 320 ||
        heightPixels > 8192 ||
        densityDpi < 72 ||
        densityDpi > 640) {
      throw ArgumentError('invalid_display');
    }
  }

  final int displayId;
  final int displayRevision;
  final bool attached;
  final int widthPixels;
  final int heightPixels;
  final int densityDpi;
  final bool secureSurface;

  @override
  bool operator ==(Object other) =>
      other is GameStreamDisplay &&
      displayId == other.displayId &&
      displayRevision == other.displayRevision &&
      attached == other.attached &&
      widthPixels == other.widthPixels &&
      heightPixels == other.heightPixels &&
      densityDpi == other.densityDpi &&
      secureSurface == other.secureSurface;

  @override
  int get hashCode => Object.hash(
    displayId,
    displayRevision,
    attached,
    widthPixels,
    heightPixels,
    densityDpi,
    secureSurface,
  );
}

final class GameStreamCodec {
  GameStreamCodec({
    required this.codecId,
    required this.codecRevision,
    required this.codec,
    required this.supported,
    required this.maxWidthPixels,
    required this.maxHeightPixels,
    required this.maxFramesPerSecond,
  }) {
    _requireId(codecId);
    _requireRevision(codecRevision);
    if (maxWidthPixels < 320 ||
        maxWidthPixels > 8192 ||
        maxHeightPixels < 320 ||
        maxHeightPixels > 8192 ||
        maxFramesPerSecond < 24 ||
        maxFramesPerSecond > 240) {
      throw ArgumentError('invalid_codec');
    }
  }

  final String codecId;
  final int codecRevision;
  final GameVideoCodec codec;
  final bool supported;
  final int maxWidthPixels;
  final int maxHeightPixels;
  final int maxFramesPerSecond;

  @override
  bool operator ==(Object other) =>
      other is GameStreamCodec &&
      codecId == other.codecId &&
      codecRevision == other.codecRevision &&
      codec == other.codec &&
      supported == other.supported &&
      maxWidthPixels == other.maxWidthPixels &&
      maxHeightPixels == other.maxHeightPixels &&
      maxFramesPerSecond == other.maxFramesPerSecond;

  @override
  int get hashCode => Object.hash(
    codecId,
    codecRevision,
    codec,
    supported,
    maxWidthPixels,
    maxHeightPixels,
    maxFramesPerSecond,
  );
}

final class GameStreamNetwork {
  GameStreamNetwork({
    required this.networkId,
    required this.networkRevision,
    required this.reachability,
    required this.metered,
  }) {
    _requireId(networkId);
    _requireRevision(networkRevision);
  }

  final String networkId;
  final int networkRevision;
  final NetworkReachability reachability;
  final bool metered;

  @override
  bool operator ==(Object other) =>
      other is GameStreamNetwork &&
      networkId == other.networkId &&
      networkRevision == other.networkRevision &&
      reachability == other.reachability &&
      metered == other.metered;

  @override
  int get hashCode =>
      Object.hash(networkId, networkRevision, reachability, metered);
}

final class GameStreamPolicy {
  GameStreamPolicy({
    required this.policyId,
    required this.policyRevision,
    required Set<String> allowedCodecIds,
    required this.allowMetered,
    required this.requirePin,
    required this.active,
    required this.maximumIdle,
    required this.maximumSession,
  }) : allowedCodecIds = Set.unmodifiable(allowedCodecIds) {
    _requireId(policyId);
    _requireRevision(policyRevision);
    if (allowedCodecIds.isEmpty ||
        allowedCodecIds.length > 8 ||
        allowedCodecIds.any((value) => !_identity.hasMatch(value)) ||
        maximumIdle < const Duration(seconds: 30) ||
        maximumIdle > const Duration(hours: 1) ||
        maximumSession < const Duration(minutes: 1) ||
        maximumSession > const Duration(hours: 12)) {
      throw ArgumentError('invalid_policy');
    }
  }

  final String policyId;
  final int policyRevision;
  final Set<String> allowedCodecIds;
  final bool allowMetered;
  final bool requirePin;
  final bool active;
  final Duration maximumIdle;
  final Duration maximumSession;

  @override
  bool operator ==(Object other) =>
      other is GameStreamPolicy &&
      policyId == other.policyId &&
      policyRevision == other.policyRevision &&
      _setEquals(allowedCodecIds, other.allowedCodecIds) &&
      allowMetered == other.allowMetered &&
      requirePin == other.requirePin &&
      active == other.active &&
      maximumIdle == other.maximumIdle &&
      maximumSession == other.maximumSession;

  @override
  int get hashCode => Object.hash(
    policyId,
    policyRevision,
    Object.hashAll(allowedCodecIds.toList()..sort()),
    allowMetered,
    requirePin,
    active,
    maximumIdle,
    maximumSession,
  );
}

final class GameStreamRevisions {
  const GameStreamRevisions._({
    required this.hostRevision,
    required this.pairingRevision,
    required this.appRevision,
    required this.displayRevision,
    required this.codecRevision,
    required this.networkRevision,
    required this.policyRevision,
  });

  factory GameStreamRevisions.fromSnapshots({
    required GameStreamHost host,
    required GameStreamApp app,
    required GameStreamDisplay display,
    required GameStreamCodec codec,
    required GameStreamNetwork network,
    required GameStreamPolicy policy,
  }) => GameStreamRevisions._(
    hostRevision: host.hostRevision,
    pairingRevision: host.pairingRevision,
    appRevision: app.appRevision,
    displayRevision: display.displayRevision,
    codecRevision: codec.codecRevision,
    networkRevision: network.networkRevision,
    policyRevision: policy.policyRevision,
  );

  final int hostRevision;
  final int pairingRevision;
  final int appRevision;
  final int displayRevision;
  final int codecRevision;
  final int networkRevision;
  final int policyRevision;

  Map<String, int> toJson() => {
    'hostRevision': hostRevision,
    'pairingRevision': pairingRevision,
    'appRevision': appRevision,
    'displayRevision': displayRevision,
    'codecRevision': codecRevision,
    'networkRevision': networkRevision,
    'policyRevision': policyRevision,
  };

  @override
  bool operator ==(Object other) =>
      other is GameStreamRevisions &&
      hostRevision == other.hostRevision &&
      pairingRevision == other.pairingRevision &&
      appRevision == other.appRevision &&
      displayRevision == other.displayRevision &&
      codecRevision == other.codecRevision &&
      networkRevision == other.networkRevision &&
      policyRevision == other.policyRevision;

  @override
  int get hashCode => Object.hash(
    hostRevision,
    pairingRevision,
    appRevision,
    displayRevision,
    codecRevision,
    networkRevision,
    policyRevision,
  );
}

final class GameStreamSessionState {
  const GameStreamSessionState._({
    required this.sessionId,
    required this.phase,
    required this.revisions,
    required this.outcomeUnknown,
  });

  final String sessionId;
  final GameStreamPhase phase;
  final GameStreamRevisions revisions;
  final bool outcomeUnknown;

  Map<String, Object> toDiagnostics() => {
    'phase': phase.name,
    'hostRevision': revisions.hostRevision,
    'appRevision': revisions.appRevision,
    'displayRevision': revisions.displayRevision,
    'codecRevision': revisions.codecRevision,
    'networkRevision': revisions.networkRevision,
    'policyRevision': revisions.policyRevision,
    'outcomeUnknown': outcomeUnknown,
  };

  @override
  String toString() => 'GameStreamSessionState(${phase.name})';
}

/// A protected, bounded transport request for low-latency tablet/DeX output.
final class GameStreamQuality {
  const GameStreamQuality({
    required this.widthPixels,
    required this.heightPixels,
    required this.framesPerSecond,
    required this.bitrateKbps,
    required this.frameQueueDepth,
    required this.inputQueueDepth,
    required this.secureSurface,
  });

  factory GameStreamQuality.fromSnapshots(
    GameStreamDisplay display,
    GameStreamCodec codec,
  ) {
    final frames = codec.maxFramesPerSecond.clamp(24, 120);
    final bitrate =
        (display.widthPixels * display.heightPixels * frames ~/ 2000).clamp(
          2000,
          100000,
        );
    return GameStreamQuality(
      widthPixels: display.widthPixels,
      heightPixels: display.heightPixels,
      framesPerSecond: frames,
      bitrateKbps: bitrate,
      frameQueueDepth: 3,
      inputQueueDepth: 32,
      secureSurface: display.secureSurface,
    );
  }

  final int widthPixels, heightPixels, framesPerSecond, bitrateKbps;
  final int frameQueueDepth, inputQueueDepth;
  final bool secureSurface;

  Map<String, Object> toJson() => {
    'widthPixels': widthPixels,
    'heightPixels': heightPixels,
    'framesPerSecond': framesPerSecond,
    'bitrateKbps': bitrateKbps,
    'frameQueueDepth': frameQueueDepth,
    'inputQueueDepth': inputQueueDepth,
    'secureSurface': secureSurface,
  };

  @override
  bool operator ==(Object other) =>
      other is GameStreamQuality &&
      widthPixels == other.widthPixels &&
      heightPixels == other.heightPixels &&
      framesPerSecond == other.framesPerSecond &&
      bitrateKbps == other.bitrateKbps &&
      frameQueueDepth == other.frameQueueDepth &&
      inputQueueDepth == other.inputQueueDepth &&
      secureSurface == other.secureSurface;

  @override
  int get hashCode => Object.hash(
    widthPixels,
    heightPixels,
    framesPerSecond,
    bitrateKbps,
    frameQueueDepth,
    inputQueueDepth,
    secureSurface,
  );
}

final class GameStreamCommand {
  const GameStreamCommand({
    required this.sessionId,
    required this.commandId,
    required this.requestId,
    required this.intent,
    required this.hostId,
    required this.appId,
    required this.displayId,
    required this.codecId,
    required this.networkId,
    required this.policyId,
    required this.revisions,
    required this.quality,
  });

  final String sessionId;
  final String commandId;
  final String requestId;
  final GameStreamIntent intent;
  final String hostId;
  final String appId;
  final int displayId;
  final String codecId;
  final String networkId;
  final String policyId;
  final GameStreamRevisions revisions;
  final GameStreamQuality quality;

  Map<String, Object> toJson() => {
    'sessionId': sessionId,
    'commandId': commandId,
    'requestId': requestId,
    'intent': intent.name,
    'hostId': hostId,
    'appId': appId,
    'displayId': displayId,
    'codecId': codecId,
    'networkId': networkId,
    'policyId': policyId,
    'revisions': revisions.toJson(),
    'quality': quality.toJson(),
  };

  @override
  String toString() => 'GameStreamCommand(${intent.name}, redacted)';
}

final class GameStreamNativeReceipt {
  GameStreamNativeReceipt({
    required this.sessionId,
    required this.commandId,
    required this.requestId,
    required this.intent,
    required this.revisions,
    required this.quality,
    required this.accepted,
    required this.observedState,
    required this.readbackRevision,
  }) {
    _requireId(sessionId);
    _requireId(commandId);
    _requireId(requestId);
    _requireRevision(readbackRevision);
  }

  final String sessionId;
  final String commandId;
  final String requestId;
  final GameStreamIntent intent;
  final GameStreamRevisions revisions;
  final GameStreamQuality quality;
  final bool accepted;
  final NativeStreamState observedState;
  final int readbackRevision;
}

final class GameStreamIntentReceipt {
  const GameStreamIntentReceipt({
    required this.requestId,
    required this.commandId,
    required this.intent,
    required this.status,
    required this.outcomeUnknown,
    this.readbackRevision,
  });

  final String requestId;
  final String commandId;
  final GameStreamIntent intent;
  final GameStreamReceiptStatus status;
  final bool outcomeUnknown;
  final int? readbackRevision;

  @override
  bool operator ==(Object other) =>
      other is GameStreamIntentReceipt &&
      requestId == other.requestId &&
      commandId == other.commandId &&
      intent == other.intent &&
      status == other.status &&
      outcomeUnknown == other.outcomeUnknown &&
      readbackRevision == other.readbackRevision;

  @override
  int get hashCode => Object.hash(
    requestId,
    commandId,
    intent,
    status,
    outcomeUnknown,
    readbackRevision,
  );
}

final class GameStreamRetirement {
  const GameStreamRetirement({required this.sessionId, required this.reason});

  final String sessionId;
  final GameStreamRetirementReason reason;
}

abstract interface class GameStreamPort {
  Future<GameStreamNativeReceipt> execute(
    GameStreamCommand command,
    Object credentialHandle,
  );

  Future<void> retire(GameStreamRetirement retirement);
}

final class GameStreamSessionCoordinator {
  GameStreamSessionCoordinator({
    required GameStreamAuthority Function() authorityResolver,
    required Object Function() accountOwnerResolver,
    required Object Function() routeOwnerResolver,
    required GameStreamHost Function() hostResolver,
    required GameStreamApp Function() appResolver,
    required GameStreamDisplay Function() displayResolver,
    required GameStreamCodec Function() codecResolver,
    required GameStreamNetwork Function() networkResolver,
    required GameStreamPolicy Function() policyResolver,
    required GameStreamPort port,
    DateTime Function()? now,
  }) : _authorityResolver = authorityResolver,
       _accountOwnerResolver = accountOwnerResolver,
       _routeOwnerResolver = routeOwnerResolver,
       _hostResolver = hostResolver,
       _appResolver = appResolver,
       _displayResolver = displayResolver,
       _codecResolver = codecResolver,
       _networkResolver = networkResolver,
       _policyResolver = policyResolver,
       _port = port,
       _now = now ?? DateTime.now;

  final GameStreamAuthority Function() _authorityResolver;
  final Object Function() _accountOwnerResolver;
  final Object Function() _routeOwnerResolver;
  final GameStreamHost Function() _hostResolver;
  final GameStreamApp Function() _appResolver;
  final GameStreamDisplay Function() _displayResolver;
  final GameStreamCodec Function() _codecResolver;
  final GameStreamNetwork Function() _networkResolver;
  final GameStreamPolicy Function() _policyResolver;
  final GameStreamPort _port;
  final DateTime Function() _now;
  final Map<GameStreamIntent, _IntentOperation> _operations = {};
  _ActiveSession? _active;
  int _epoch = 0;
  GameStreamSessionState? _state;

  GameStreamSessionState get state =>
      _state ?? (throw const GameStreamException('session_missing'));

  GameStreamSessionState open({
    required GameStreamAuthority authority,
    required Object accountOwner,
    required Object routeOwner,
    required GameStreamHost host,
    required GameStreamApp app,
    required GameStreamDisplay display,
    required GameStreamCodec codec,
    required GameStreamNetwork network,
    required GameStreamPolicy policy,
    required Object credentialHandle,
  }) {
    if (_active != null &&
        state.phase != GameStreamPhase.retired &&
        state.phase != GameStreamPhase.stopped) {
      throw const GameStreamException('session_busy');
    }
    if (!identical(_accountOwnerResolver(), accountOwner) ||
        !identical(_routeOwnerResolver(), routeOwner) ||
        _authorityResolver() != authority ||
        _hostResolver() != host ||
        _appResolver() != app ||
        _displayResolver() != display ||
        _codecResolver() != codec ||
        _networkResolver() != network ||
        _policyResolver() != policy) {
      throw const GameStreamException('stale_snapshot');
    }
    _validateAuthority(authority, policy);
    if (!policy.active ||
        !host.paired ||
        !app.launchable ||
        !display.attached ||
        !display.secureSurface ||
        !codec.supported ||
        app.hostId != host.hostId ||
        app.hostRevision != host.hostRevision ||
        !policy.allowedCodecIds.contains(codec.codecId) ||
        display.widthPixels > codec.maxWidthPixels ||
        display.heightPixels > codec.maxHeightPixels ||
        network.reachability != NetworkReachability.local ||
        (network.metered && !policy.allowMetered)) {
      throw const GameStreamException('unsupported_session');
    }
    final revisions = GameStreamRevisions.fromSnapshots(
      host: host,
      app: app,
      display: display,
      codec: codec,
      network: network,
      policy: policy,
    );
    final epoch = ++_epoch;
    final sessionId = _hash32(
      '${host.hostId}:${app.appId}:${display.displayId}:$epoch:${revisions.toJson()}',
    );
    _operations.clear();
    _active = _ActiveSession(
      epoch: epoch,
      sessionId: sessionId,
      authority: authority,
      accountOwner: accountOwner,
      routeOwner: routeOwner,
      host: host,
      app: app,
      display: display,
      codec: codec,
      network: network,
      policy: policy,
      revisions: revisions,
      credentialHandle: credentialHandle,
      openedAt: _now().toUtc(),
    );
    return _state = GameStreamSessionState._(
      sessionId: sessionId,
      phase: host.powerState == HostPowerState.awake
          ? GameStreamPhase.ready
          : GameStreamPhase.created,
      revisions: revisions,
      outcomeUnknown: false,
    );
  }

  Future<GameStreamIntentReceipt> dispatch({
    required GameStreamIntent intent,
    required String requestId,
  }) {
    _requireId(requestId);
    final active = _active;
    if (active == null) {
      throw const GameStreamException('session_missing');
    }
    final fingerprint = '${active.sessionId}:${intent.name}:$requestId';
    final existing = _operations[intent];
    if (existing != null) {
      if (existing.fingerprint != fingerprint) {
        throw const GameStreamException('idempotency_conflict');
      }
      return existing.completer.future;
    }
    _assertCurrent(active);
    if (!_allowed(state.phase, intent)) {
      throw const GameStreamException('invalid_intent');
    }
    final command = GameStreamCommand(
      sessionId: active.sessionId,
      commandId: _hash32(fingerprint),
      requestId: requestId,
      intent: intent,
      hostId: active.host.hostId,
      appId: active.app.appId,
      displayId: active.display.displayId,
      codecId: active.codec.codecId,
      networkId: active.network.networkId,
      policyId: active.policy.policyId,
      revisions: active.revisions,
      quality: GameStreamQuality.fromSnapshots(active.display, active.codec),
    );
    final operation = _IntentOperation(
      fingerprint: fingerprint,
      command: command,
      completer: Completer<GameStreamIntentReceipt>(),
    );
    _operations[intent] = operation;
    unawaited(_execute(active, command, operation));
    return operation.completer.future;
  }

  Future<void> _execute(
    _ActiveSession active,
    GameStreamCommand command,
    _IntentOperation operation,
  ) async {
    GameStreamNativeReceipt? native;
    try {
      native = await _port.execute(command, active.credentialHandle);
    } catch (_) {
      native = null;
    }
    final sameLease = _active?.epoch == active.epoch;
    final stillCurrent = sameLease && _currentSafely(active);
    if (sameLease && !stillCurrent) {
      await _retire(GameStreamRetirementReason.authorityChanged);
    }
    final expected = _expectedState(command.intent);
    final exact =
        native != null &&
        native.sessionId == command.sessionId &&
        native.commandId == command.commandId &&
        native.requestId == command.requestId &&
        native.intent == command.intent &&
        native.revisions == command.revisions &&
        native.quality == command.quality;
    late final GameStreamIntentReceipt receipt;
    if (!stillCurrent || !exact) {
      receipt = GameStreamIntentReceipt(
        requestId: command.requestId,
        commandId: command.commandId,
        intent: command.intent,
        status: GameStreamReceiptStatus.unknown,
        outcomeUnknown: true,
      );
      if (stillCurrent) _markUnknown(active);
    } else if (native.accepted && native.observedState == expected) {
      receipt = GameStreamIntentReceipt(
        requestId: command.requestId,
        commandId: command.commandId,
        intent: command.intent,
        status: GameStreamReceiptStatus.verified,
        outcomeUnknown: false,
        readbackRevision: native.readbackRevision,
      );
      _state = GameStreamSessionState._(
        sessionId: active.sessionId,
        phase: _verifiedPhase(command.intent),
        revisions: active.revisions,
        outcomeUnknown: false,
      );
    } else if (!native.accepted &&
        native.observedState == NativeStreamState.rejected) {
      receipt = GameStreamIntentReceipt(
        requestId: command.requestId,
        commandId: command.commandId,
        intent: command.intent,
        status: GameStreamReceiptStatus.rejected,
        outcomeUnknown: false,
        readbackRevision: native.readbackRevision,
      );
      _state = GameStreamSessionState._(
        sessionId: active.sessionId,
        phase: GameStreamPhase.rejected,
        revisions: active.revisions,
        outcomeUnknown: false,
      );
    } else {
      receipt = GameStreamIntentReceipt(
        requestId: command.requestId,
        commandId: command.commandId,
        intent: command.intent,
        status: GameStreamReceiptStatus.unknown,
        outcomeUnknown: true,
      );
      _markUnknown(active);
    }
    if (!operation.completer.isCompleted) {
      operation.completer.complete(receipt);
    }
  }

  Future<GameStreamSessionState> reconcile() async {
    final active = _active;
    if (active == null) return state;
    GameStreamDisplay display;
    try {
      display = _displayResolver();
    } catch (_) {
      return _retire(GameStreamRetirementReason.snapshotChanged);
    }
    if (!display.attached || display.displayId != active.display.displayId) {
      return _retire(GameStreamRetirementReason.displayDetached);
    }
    if (!_authorityCurrentSafely(active)) {
      return _retire(GameStreamRetirementReason.authorityChanged);
    }
    if (!_snapshotsCurrentSafely(active)) {
      return _retire(GameStreamRetirementReason.snapshotChanged);
    }
    if (_now().toUtc().isAfter(
      active.openedAt.add(active.policy.maximumSession),
    )) {
      return _retire(GameStreamRetirementReason.sessionExpired);
    }
    return state;
  }

  Future<GameStreamSessionState> retire() =>
      _retire(GameStreamRetirementReason.explicit);

  Future<GameStreamSessionState> _retire(
    GameStreamRetirementReason reason,
  ) async {
    final active = _active;
    if (active == null || state.phase == GameStreamPhase.retired) return state;
    _epoch++;
    _active = null;
    _state = GameStreamSessionState._(
      sessionId: active.sessionId,
      phase: GameStreamPhase.retired,
      revisions: active.revisions,
      outcomeUnknown: false,
    );
    for (final operation in _operations.values) {
      if (!operation.completer.isCompleted) {
        operation.completer.complete(
          GameStreamIntentReceipt(
            requestId: operation.command.requestId,
            commandId: operation.command.commandId,
            intent: operation.command.intent,
            status: GameStreamReceiptStatus.unknown,
            outcomeUnknown: true,
          ),
        );
      }
    }
    try {
      await _port.retire(
        GameStreamRetirement(sessionId: active.sessionId, reason: reason),
      );
    } catch (_) {
      // Retirement is one-way even if the native cleanup acknowledgement is lost.
    }
    return state;
  }

  void _assertCurrent(_ActiveSession active) {
    if (!_currentSafely(active)) {
      unawaited(_retire(GameStreamRetirementReason.authorityChanged));
      throw const GameStreamException('stale_session');
    }
  }

  bool _currentSafely(_ActiveSession active) {
    try {
      return _current(active);
    } catch (_) {
      return false;
    }
  }

  bool _current(_ActiveSession active) =>
      _active?.epoch == active.epoch &&
      _authorityCurrentSafely(active) &&
      _snapshotsCurrentSafely(active) &&
      !_now().toUtc().isAfter(
        active.openedAt.add(active.policy.maximumSession),
      );

  bool _authorityCurrentSafely(_ActiveSession active) {
    try {
      return _authorityCurrent(active);
    } catch (_) {
      return false;
    }
  }

  bool _snapshotsCurrentSafely(_ActiveSession active) {
    try {
      return _snapshotsCurrent(active);
    } catch (_) {
      return false;
    }
  }

  bool _authorityCurrent(_ActiveSession active) {
    final authority = _authorityResolver();
    return identical(_accountOwnerResolver(), active.accountOwner) &&
        identical(_routeOwnerResolver(), active.routeOwner) &&
        authority == active.authority &&
        _authorityAllowed(authority, active.policy);
  }

  bool _snapshotsCurrent(_ActiveSession active) =>
      _hostResolver() == active.host &&
      _appResolver() == active.app &&
      _displayResolver() == active.display &&
      _codecResolver() == active.codec &&
      _networkResolver() == active.network &&
      _policyResolver() == active.policy;

  void _validateAuthority(
    GameStreamAuthority authority,
    GameStreamPolicy policy,
  ) {
    if (!_authorityAllowed(authority, policy)) {
      throw const GameStreamException('authority_denied');
    }
  }

  bool _authorityAllowed(
    GameStreamAuthority authority,
    GameStreamPolicy policy,
  ) =>
      authority.foreground &&
      authority.routeVisible &&
      authority.interactionActive &&
      !authority.idle &&
      authority.idleFor <= policy.maximumIdle &&
      (!policy.requirePin || authority.pinUnlocked);

  void _markUnknown(_ActiveSession active) {
    _state = GameStreamSessionState._(
      sessionId: active.sessionId,
      phase: GameStreamPhase.outcomeUnknown,
      revisions: active.revisions,
      outcomeUnknown: true,
    );
  }

  @override
  String toString() => 'GameStreamSessionCoordinator(redacted)';
}

final class _ActiveSession {
  const _ActiveSession({
    required this.epoch,
    required this.sessionId,
    required this.authority,
    required this.accountOwner,
    required this.routeOwner,
    required this.host,
    required this.app,
    required this.display,
    required this.codec,
    required this.network,
    required this.policy,
    required this.revisions,
    required this.credentialHandle,
    required this.openedAt,
  });

  final int epoch;
  final String sessionId;
  final GameStreamAuthority authority;
  final Object accountOwner;
  final Object routeOwner;
  final GameStreamHost host;
  final GameStreamApp app;
  final GameStreamDisplay display;
  final GameStreamCodec codec;
  final GameStreamNetwork network;
  final GameStreamPolicy policy;
  final GameStreamRevisions revisions;
  final Object credentialHandle;
  final DateTime openedAt;
}

final class _IntentOperation {
  const _IntentOperation({
    required this.fingerprint,
    required this.command,
    required this.completer,
  });

  final String fingerprint;
  final GameStreamCommand command;
  final Completer<GameStreamIntentReceipt> completer;
}

bool _allowed(GameStreamPhase phase, GameStreamIntent intent) =>
    switch (intent) {
      GameStreamIntent.wake => phase == GameStreamPhase.created,
      GameStreamIntent.launch => phase == GameStreamPhase.ready,
      GameStreamIntent.stream => phase == GameStreamPhase.launched,
      GameStreamIntent.stop => phase == GameStreamPhase.streaming,
    };

NativeStreamState _expectedState(GameStreamIntent intent) => switch (intent) {
  GameStreamIntent.wake => NativeStreamState.hostAwake,
  GameStreamIntent.launch => NativeStreamState.appRunning,
  GameStreamIntent.stream => NativeStreamState.streaming,
  GameStreamIntent.stop => NativeStreamState.stopped,
};

GameStreamPhase _verifiedPhase(GameStreamIntent intent) => switch (intent) {
  GameStreamIntent.wake => GameStreamPhase.ready,
  GameStreamIntent.launch => GameStreamPhase.launched,
  GameStreamIntent.stream => GameStreamPhase.streaming,
  GameStreamIntent.stop => GameStreamPhase.stopped,
};

String _hash32(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 32);

void _requireId(String value) {
  if (!_identity.hasMatch(value)) throw ArgumentError('invalid_identity');
}

void _requireRevision(int value) {
  if (value < 1 || value > 9223372036854775806) {
    throw ArgumentError('invalid_revision');
  }
}

bool _setEquals<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);

final _identity = RegExp(r'^[0-9a-f]{32}$');
