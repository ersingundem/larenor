import 'package:flutter/services.dart';

import '../domain/game_stream_session.dart';
import 'core_game_stream_api.dart';

const _channelName = 'com.ersingundem.larenor/game-stream-native';

final class AndroidGameStreamAuthorityV2 {
  AndroidGameStreamAuthorityV2({
    required this.clientInstanceId,
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.familyId,
    required this.accountRevision,
    required this.pinRevision,
    required this.pinConfigured,
    required this.pinUnlocked,
    required this.routeRevision,
    required this.lifecycleRevision,
    required this.idleRevision,
    required this.interactionRevision,
  }) {
    for (final value in [
      clientInstanceId,
      coreId,
      homeId,
      accountId,
      familyId,
    ]) {
      _identity(value);
    }
    for (final value in [
      accountRevision,
      pinRevision,
      routeRevision,
      lifecycleRevision,
      idleRevision,
      interactionRevision,
    ]) {
      _revision(value);
    }
  }

  final String clientInstanceId, coreId, homeId, accountId, familyId;
  final int accountRevision, pinRevision, routeRevision;
  final int lifecycleRevision, idleRevision, interactionRevision;
  final bool pinConfigured, pinUnlocked;

  factory AndroidGameStreamAuthorityV2.fromJson(Object? raw) {
    final value = _exactMap(raw, {
      'coreId',
      'clientInstanceId',
      'homeId',
      'accountId',
      'familyId',
      'accountRevision',
      'pinRevision',
      'pinConfigured',
      'pinUnlocked',
      'routeRevision',
      'lifecycleRevision',
      'idleRevision',
      'interactionRevision',
    });
    final pinConfigured = value['pinConfigured'];
    final pinUnlocked = value['pinUnlocked'];
    if (pinConfigured is! bool || pinUnlocked is! bool) {
      throw const GameStreamException('invalid_native_authority');
    }
    return AndroidGameStreamAuthorityV2(
      clientInstanceId: _identity(value['clientInstanceId']),
      coreId: _identity(value['coreId']),
      homeId: _identity(value['homeId']),
      accountId: _identity(value['accountId']),
      familyId: _identity(value['familyId']),
      accountRevision: _revision(value['accountRevision']),
      pinRevision: _revision(value['pinRevision']),
      pinConfigured: pinConfigured,
      pinUnlocked: pinUnlocked,
      routeRevision: _revision(value['routeRevision']),
      lifecycleRevision: _revision(value['lifecycleRevision']),
      idleRevision: _revision(value['idleRevision']),
      interactionRevision: _revision(value['interactionRevision']),
    );
  }

  bool get satisfiesRequiredPin => pinConfigured && pinUnlocked;

  Map<String, Object> toJson() => {
    'clientInstanceId': clientInstanceId,
    'coreId': coreId,
    'homeId': homeId,
    'accountId': accountId,
    'familyId': familyId,
    'accountRevision': accountRevision,
    'pinRevision': pinRevision,
    'pinConfigured': pinConfigured,
    'pinUnlocked': pinUnlocked,
    'routeRevision': routeRevision,
    'lifecycleRevision': lifecycleRevision,
    'idleRevision': idleRevision,
    'interactionRevision': interactionRevision,
  };
}

final class AndroidGameStreamCandidate {
  const AndroidGameStreamCandidate._({
    required this.id,
    required this.revision,
    required this.name,
    required this.powerState,
    required this.pairState,
  });

  final String id, name, powerState, pairState;
  final int revision;
}

final class AndroidGameStreamDiscovery {
  const AndroidGameStreamDiscovery._({
    required this.requestId,
    required this.nativeBindingId,
    required this.bindingRevision,
    required this.engineRevision,
    required this.catalogRevision,
    required this.catalogDigest,
    required this.candidates,
  });

  final String requestId, nativeBindingId, engineRevision, catalogDigest;
  final int bindingRevision, catalogRevision;
  final List<AndroidGameStreamCandidate> candidates;

  factory AndroidGameStreamDiscovery.recovery(
    CoreNativePairingObservation observation,
  ) => AndroidGameStreamDiscovery._(
    requestId: observation.receiptId,
    nativeBindingId: observation.nativeBindingId,
    bindingRevision: observation.bindingRevision,
    engineRevision: observation.engineRevision,
    catalogRevision: observation.catalogRevision,
    catalogDigest: observation.catalogDigest,
    candidates: const [],
  );
}

final class AndroidGameStreamPairingReceipt {
  const AndroidGameStreamPairingReceipt._({
    required this.requestId,
    required this.pairingId,
    required this.state,
    required this.nativeReceiptDigest,
    required this.observation,
  });

  final String requestId, pairingId, state, nativeReceiptDigest;
  final CoreNativePairingObservation? observation;
}

final class AndroidGameStreamCatalogReceipt {
  const AndroidGameStreamCatalogReceipt._({
    required this.requestId,
    required this.catalogObservationId,
    required this.state,
    required this.nativeReceiptDigest,
    required this.observation,
  });

  final String requestId, catalogObservationId, state, nativeReceiptDigest;
  final CoreNativeCatalogObservation? observation;
}

final class AndroidGameStreamRegistrationReceipt {
  const AndroidGameStreamRegistrationReceipt._({
    required this.requestId,
    required this.registrationRevision,
    required this.hostId,
    required this.appIds,
    required this.nativeReceiptDigest,
  });

  final String requestId, hostId, nativeReceiptDigest;
  final int registrationRevision;
  final List<String> appIds;
}

final class AndroidGameStreamResolvedBinding {
  const AndroidGameStreamResolvedBinding._({
    required this.requestId,
    required this.nativeBindingId,
    required this.bindingRevision,
    required this.registrationRevision,
    required this.hostId,
    required this.appId,
    required this.engineRevision,
  });

  final String requestId, nativeBindingId, hostId, appId, engineRevision;
  final int bindingRevision, registrationRevision;
}

final class AndroidGameStreamHostBinding {
  const AndroidGameStreamHostBinding._({
    required this.nativeBindingId,
    required this.bindingRevision,
    required this.registrationRevision,
    required this.hostId,
    required this.engineRevision,
  });

  final String nativeBindingId, hostId, engineRevision;
  final int bindingRevision, registrationRevision;

  factory AndroidGameStreamHostBinding.recovery({
    required String nativeBindingId,
    required int bindingRevision,
    required int registrationRevision,
    required String hostId,
    required String engineRevision,
  }) => AndroidGameStreamHostBinding._(
    nativeBindingId: _identity(nativeBindingId),
    bindingRevision: _revision(bindingRevision),
    registrationRevision: _revision(registrationRevision),
    hostId: _identity(hostId),
    engineRevision: _engineRevision(engineRevision),
  );
}

final class AndroidGameStreamPolicyDraft {
  AndroidGameStreamPolicyDraft({
    required this.allowedCodecs,
    required this.allowMetered,
    required this.requirePin,
    required this.maxWidth,
    required this.maxHeight,
    required this.maxFps,
    required this.maxBitrateKbps,
    required this.maximumIdleSeconds,
    required this.maximumSessionSeconds,
    required this.frameQueueDepth,
    required this.inputQueueDepth,
  }) {
    if (allowedCodecs.isEmpty ||
        allowedCodecs.length > 3 ||
        allowedCodecs.toSet().length != allowedCodecs.length ||
        allowedCodecs.any(
          (value) => !{'h264', 'hevc', 'av1'}.contains(value),
        ) ||
        maxWidth < 320 ||
        maxWidth > 8192 ||
        maxHeight < 320 ||
        maxHeight > 8192 ||
        maxFps < 24 ||
        maxFps > 240 ||
        maxBitrateKbps < 2000 ||
        maxBitrateKbps > 100000 ||
        maximumIdleSeconds < 30 ||
        maximumIdleSeconds > 3600 ||
        maximumSessionSeconds < 60 ||
        maximumSessionSeconds > 3600 ||
        frameQueueDepth < 1 ||
        frameQueueDepth > 3 ||
        inputQueueDepth < 1 ||
        inputQueueDepth > 32) {
      throw ArgumentError('invalid_stream_policy');
    }
  }

  final List<String> allowedCodecs;
  final bool allowMetered, requirePin;
  final int maxWidth, maxHeight, maxFps, maxBitrateKbps;
  final int maximumIdleSeconds, maximumSessionSeconds;
  final int frameQueueDepth, inputQueueDepth;

  Map<String, Object> toJson() => {
    'allowedCodecs': List.unmodifiable(allowedCodecs),
    'allowMetered': allowMetered,
    'requirePin': requirePin,
    'maxWidth': maxWidth,
    'maxHeight': maxHeight,
    'maxFps': maxFps,
    'maxBitrateKbps': maxBitrateKbps,
    'maximumIdleSeconds': maximumIdleSeconds,
    'maximumSessionSeconds': maximumSessionSeconds,
    'frameQueueDepth': frameQueueDepth,
    'inputQueueDepth': inputQueueDepth,
  };
}

final class AndroidGameStreamPolicyReceipt {
  const AndroidGameStreamPolicyReceipt._({
    required this.requestId,
    required this.policyId,
    required this.policyRevision,
  });

  final String requestId, policyId;
  final int policyRevision;
}

final class AndroidGameStreamDisplayObservation {
  const AndroidGameStreamDisplayObservation._({
    required this.id,
    required this.revision,
    required this.attached,
    required this.widthPixels,
    required this.heightPixels,
    required this.densityDpi,
    required this.secureSurface,
    required this.maxRefreshRate,
  });

  final int id;
  final int revision, widthPixels, heightPixels, densityDpi, maxRefreshRate;
  final bool attached, secureSurface;
}

final class AndroidGameStreamNetworkObservation {
  const AndroidGameStreamNetworkObservation._({
    required this.id,
    required this.revision,
    required this.reachability,
    required this.metered,
  });

  final String id, reachability;
  final int revision;
  final bool metered;
}

final class AndroidGameStreamDecoderObservation {
  const AndroidGameStreamDecoderObservation._({
    required this.id,
    required this.revision,
    required this.codec,
    required this.supported,
    required this.maxWidthPixels,
    required this.maxHeightPixels,
    required this.maxFramesPerSecond,
  });

  final String id, codec;
  final int revision, maxWidthPixels, maxHeightPixels, maxFramesPerSecond;
  final bool supported;
}

final class AndroidGameStreamPolicyObservation {
  const AndroidGameStreamPolicyObservation._({
    required this.id,
    required this.revision,
    required this.allowedCodecIds,
    required this.allowMetered,
    required this.requirePin,
    required this.maxWidth,
    required this.maxHeight,
    required this.maxFps,
    required this.maxBitrateKbps,
    required this.maximumIdleSeconds,
    required this.maximumSessionSeconds,
    required this.frameQueueDepth,
    required this.inputQueueDepth,
  });

  final String id;
  final int revision;
  final List<String> allowedCodecIds;
  final bool allowMetered, requirePin;
  final int maxWidth, maxHeight, maxFps, maxBitrateKbps;
  final int maximumIdleSeconds, maximumSessionSeconds;
  final int frameQueueDepth, inputQueueDepth;
}

final class AndroidGameStreamQualityOption {
  const AndroidGameStreamQualityOption._({required this.selectedQuality});

  final CoreGameStreamSelectedQuality selectedQuality;
  String get codecId => selectedQuality.codecId;
  int get widthPixels => selectedQuality.widthPixels;
  int get heightPixels => selectedQuality.heightPixels;
  int get framesPerSecond => selectedQuality.framesPerSecond;
  int get bitrateKbps => selectedQuality.bitrateKbps;

  Map<String, Object> toJson() => selectedQuality.toJson();
}

final class AndroidGameStreamSessionCapabilities {
  const AndroidGameStreamSessionCapabilities._({
    required this.requestId,
    required this.available,
    required this.reason,
    required this.display,
    required this.network,
    required this.decoders,
    required this.policy,
    required this.qualityOptions,
  });

  final String requestId;
  final bool available;
  final String? reason;
  final AndroidGameStreamDisplayObservation? display;
  final AndroidGameStreamNetworkObservation? network;
  final List<AndroidGameStreamDecoderObservation> decoders;
  final AndroidGameStreamPolicyObservation? policy;
  final List<AndroidGameStreamQualityOption> qualityOptions;

  /// Builds the policy ceiling from current Android facts. Sunshine's public
  /// server-info response does not advertise resolution or frame-rate maxima.
  AndroidGameStreamPolicyDraft? explicitPolicyDraft(CoreGameStreamHost host) {
    final currentDisplay = display;
    if (currentDisplay == null ||
        !currentDisplay.attached ||
        !currentDisplay.secureSurface) {
      return null;
    }
    final compatible = decoders
        .where(
          (decoder) =>
              decoder.supported &&
              host.codecs.contains(decoder.codec) &&
              decoder.maxWidthPixels >= 320 &&
              decoder.maxHeightPixels >= 320 &&
              decoder.maxFramesPerSecond >= 24,
        )
        .toList(growable: false);
    if (compatible.isEmpty) return null;
    final codecs = <String>[];
    for (final decoder in compatible) {
      if (!codecs.contains(decoder.codec)) codecs.add(decoder.codec);
    }
    final decoderWidth = compatible.fold<int>(
      0,
      (value, decoder) =>
          decoder.maxWidthPixels > value ? decoder.maxWidthPixels : value,
    );
    final decoderHeight = compatible.fold<int>(
      0,
      (value, decoder) =>
          decoder.maxHeightPixels > value ? decoder.maxHeightPixels : value,
    );
    final decoderFps = compatible.fold<int>(
      0,
      (value, decoder) => decoder.maxFramesPerSecond > value
          ? decoder.maxFramesPerSecond
          : value,
    );
    final maxWidth = currentDisplay.widthPixels < decoderWidth
        ? currentDisplay.widthPixels
        : decoderWidth;
    final maxHeight = currentDisplay.heightPixels < decoderHeight
        ? currentDisplay.heightPixels
        : decoderHeight;
    final maxFps = currentDisplay.maxRefreshRate < decoderFps
        ? currentDisplay.maxRefreshRate
        : decoderFps;
    if (maxWidth < 320 || maxHeight < 320 || maxFps < 24) return null;
    return AndroidGameStreamPolicyDraft(
      allowedCodecs: List.unmodifiable(codecs),
      allowMetered: false,
      requirePin: true,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      maxFps: maxFps,
      maxBitrateKbps: 50000,
      maximumIdleSeconds: 300,
      maximumSessionSeconds: 3600,
      frameQueueDepth: 2,
      inputQueueDepth: 1,
    );
  }

  CoreGameStreamClientAuthority coreAuthority({
    required int routeRevision,
    required int lifecycleRevision,
  }) {
    if (!available || display == null || network == null || policy == null) {
      throw const GameStreamException('session_capability_unavailable');
    }
    return CoreGameStreamClientAuthority(
      routeRevision: _revision(routeRevision),
      lifecycleRevision: _revision(lifecycleRevision),
      displayRevision: display!.revision,
      networkRevision: network!.revision,
      policyRevision: policy!.revision,
    );
  }

  CoreGameStreamSelectedQuality selectedQuality(
    AndroidGameStreamQualityOption option,
  ) {
    if (!available ||
        display == null ||
        network == null ||
        policy == null ||
        !qualityOptions.contains(option)) {
      throw const GameStreamException('session_capability_unavailable');
    }
    final matches = decoders
        .where((decoder) => decoder.id == option.codecId && decoder.supported)
        .toList(growable: false);
    if (matches.length != 1 ||
        !policy!.allowedCodecIds.contains(option.codecId) ||
        option.selectedQuality.widthPixels > policy!.maxWidth ||
        option.selectedQuality.heightPixels > policy!.maxHeight ||
        option.selectedQuality.framesPerSecond > policy!.maxFps ||
        option.selectedQuality.bitrateKbps > policy!.maxBitrateKbps ||
        option.selectedQuality.displayId != display!.id ||
        option.selectedQuality.displayRevision != display!.revision ||
        option.selectedQuality.networkId != network!.id ||
        option.selectedQuality.networkRevision != network!.revision ||
        option.selectedQuality.policyId != policy!.id ||
        option.selectedQuality.policyRevision != policy!.revision ||
        option.selectedQuality.codecRevision != matches.single.revision ||
        option.selectedQuality.codec != matches.single.codec) {
      throw const GameStreamException('invalid_quality_option');
    }
    return option.selectedQuality;
  }
}

final class AndroidGameStreamCommandReceiptV2 {
  const AndroidGameStreamCommandReceiptV2._({
    required this.requestId,
    required this.sessionId,
    required this.commandId,
    required this.state,
    required this.result,
    required this.observationKind,
    required this.readbackRevision,
    required this.nativeReceiptDigest,
  });

  final String requestId, sessionId, commandId, state, result;
  final String observationKind;
  final int? readbackRevision;
  final String? nativeReceiptDigest;
}

final class AndroidGameStreamRevocationReceipt {
  const AndroidGameStreamRevocationReceipt._({
    required this.requestId,
    required this.revocationId,
    required this.state,
    required this.readbackRevision,
    required this.nativeReceiptDigest,
  });

  final String requestId, revocationId, state;
  final String? nativeReceiptDigest;
  final int? readbackRevision;
}

final class AndroidGameStreamAuthorityRetirementReceipt {
  const AndroidGameStreamAuthorityRetirementReceipt._({
    required this.requestId,
    required this.authorityId,
    required this.authorityEpoch,
    required this.nativeBindingId,
    required this.bindingRevision,
  });

  final String requestId, authorityId, nativeBindingId;
  final int authorityEpoch, bindingRevision;
}

enum AndroidGameStreamForegroundCoverage { unavailable, pairingPrompt, game }

final class AndroidGameStreamForegroundCoverageReceipt {
  const AndroidGameStreamForegroundCoverageReceipt._({
    required this.coverage,
    required this.state,
  });

  final AndroidGameStreamForegroundCoverage coverage;
  final String state;
  bool get owned => coverage != AndroidGameStreamForegroundCoverage.unavailable;
}

abstract interface class GameStreamNativeV2Port {
  Future<AndroidGameStreamDiscovery> beginPairing({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required int timeoutMs,
  });

  Future<AndroidGameStreamPairingReceipt> pair({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamDiscovery discovery,
    required CoreGameStreamPairingIntent intent,
    required AndroidGameStreamCandidate candidate,
  });

  Future<AndroidGameStreamPairingReceipt?> reconcilePairing({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required String pairingId,
  });

  Future<AndroidGameStreamRegistrationReceipt> commitRegistration({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamDiscovery discovery,
    required CoreGameStreamRegistration registration,
  });

  Future<AndroidGameStreamCatalogReceipt> readCatalog({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamHostBinding binding,
    required CoreGameStreamHost host,
    required CoreGameStreamCatalogIntent intent,
  });

  Future<AndroidGameStreamRegistrationReceipt> commitCatalogRegistration({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamHostBinding binding,
    required CoreGameStreamCatalogUpdate update,
  });

  Future<AndroidGameStreamCatalogReceipt?> reconcileCatalog({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required String catalogObservationId,
  });

  Future<AndroidGameStreamResolvedBinding> resolveBinding({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required CoreGameStreamHost host,
    required CoreGameStreamApp app,
  });

  Future<AndroidGameStreamHostBinding> resolveHostBinding({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required CoreGameStreamHost host,
  });

  Future<AndroidGameStreamPolicyReceipt> configurePolicy({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required int expectedPolicyRevision,
    required AndroidGameStreamPolicyDraft policy,
  });

  Future<AndroidGameStreamSessionCapabilities> sessionCapabilities({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required CoreGameStreamHost host,
    required CoreGameStreamApp app,
  });

  Future<void> bindSession({
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamResolvedBinding binding,
    required CoreGameStreamSession session,
    required CoreGameStreamSelectedQuality selectedQuality,
  });

  Future<AndroidGameStreamCommandReceiptV2> executeV2({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required CoreGameStreamSession session,
    required CoreGameStreamAuthorization authorization,
    AndroidGameStreamResolvedBinding? safetyClosure,
  });

  Future<AndroidGameStreamCommandReceiptV2?> reconcileCommand({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required String commandId,
  });

  Future<AndroidGameStreamForegroundCoverageReceipt> foregroundLease({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamResolvedBinding binding,
    required CoreGameStreamSession session,
  });

  Future<AndroidGameStreamForegroundCoverageReceipt> pairingPrompt({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamDiscovery discovery,
    required CoreGameStreamPairingIntent intent,
  });

  Future<AndroidGameStreamRevocationReceipt?> reconcileRevocation({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required String revocationId,
  });

  Future<AndroidGameStreamRevocationReceipt> revokePairing({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required CoreGameStreamRevocation revocation,
    required CoreGameStreamHost host,
  });

  Future<AndroidGameStreamAuthorityRetirementReceipt> retireAuthority({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    String? nativeBindingId,
    int? bindingRevision,
  });

  Future<void> retireV2({required String sessionId, required int epoch});
}

final class AndroidGameStreamV2Port implements GameStreamNativeV2Port {
  AndroidGameStreamV2Port({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  final MethodChannel _channel;
  int _generation = 0;

  void retireLocally() => _generation += 1;

  Future<T> _call<T>(
    String method,
    Map<String, Object?> arguments,
    T Function(Object?) parse,
  ) async {
    final generation = _generation;
    final raw = await _channel.invokeMethod<Object?>(method, arguments);
    if (generation != _generation) {
      throw const GameStreamException('stale_native_callback');
    }
    return parse(raw);
  }

  @override
  Future<AndroidGameStreamDiscovery> beginPairing({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required int timeoutMs,
  }) => _call('beginPairingV2', {
    'schemaVersion': 2,
    'requestId': _identity(requestId),
    'authority': authority.toJson(),
    'timeoutMs': _integer(timeoutMs, 1000, 120000),
  }, (raw) => _discovery(raw, requestId));

  @override
  Future<AndroidGameStreamPairingReceipt> pair({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamDiscovery discovery,
    required CoreGameStreamPairingIntent intent,
    required AndroidGameStreamCandidate candidate,
  }) {
    final grant = intent.pairingGrant;
    if (grant == null) {
      throw const GameStreamException('pairing_reconcile_required');
    }
    return _call('pairHostV2', {
      'schemaVersion': 2,
      'requestId': _identity(requestId),
      'authority': authority.toJson(),
      'nativeBindingId': discovery.nativeBindingId,
      'expectedBindingRevision': discovery.bindingRevision,
      'pairingId': intent.id,
      'expectedPairingRevision': intent.revision,
      'pairingGrant': grant,
      'expiresAt': intent.expiresAt.millisecondsSinceEpoch / 1000,
      'candidateId': candidate.id,
      'expectedCandidateRevision': candidate.revision,
    }, (raw) => _pairingReceipt(raw, requestId, intent.id));
  }

  @override
  Future<AndroidGameStreamPairingReceipt?> reconcilePairing({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required String pairingId,
  }) => _reconcile(
    requestId: requestId,
    authority: authority,
    operationKind: 'pair',
    operationId: pairingId,
    parse: (raw) => _pairingReceipt(raw, requestId, pairingId),
  );

  @override
  Future<AndroidGameStreamRegistrationReceipt> commitRegistration({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamDiscovery discovery,
    required CoreGameStreamRegistration registration,
  }) => _call('commitRegistrationV2', {
    'schemaVersion': 2,
    'requestId': _identity(requestId),
    'authority': authority.toJson(),
    'nativeBindingId': discovery.nativeBindingId,
    'expectedBindingRevision': discovery.bindingRevision,
    'nativeReceiptId': registration.nativeReceiptId,
    'host': {
      'id': registration.host.id,
      'revision': registration.host.revision,
      'pairingRevision': registration.host.pairingRevision,
      'catalogRevision': registration.host.catalogRevision,
    },
    'apps': registration.mapping
        .map(
          (item) => {
            'entryIndex': item.entryIndex,
            'id': item.app.id,
            'revision': item.app.revision,
          },
        )
        .toList(growable: false),
  }, (raw) => _registrationReceipt(raw, requestId, registration));

  @override
  Future<AndroidGameStreamResolvedBinding> resolveBinding({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required CoreGameStreamHost host,
    required CoreGameStreamApp app,
  }) => _call('resolveBindingV2', {
    'schemaVersion': 2,
    'requestId': _identity(requestId),
    'authority': authority.toJson(),
    'hostId': host.id,
    'expectedHostRevision': host.revision,
    'expectedPairingRevision': host.pairingRevision,
    'expectedCatalogRevision': host.catalogRevision,
    'appId': app.id,
    'expectedAppRevision': app.revision,
  }, (raw) => _resolvedBinding(raw, requestId, host.id, app.id));

  @override
  Future<AndroidGameStreamHostBinding> resolveHostBinding({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required CoreGameStreamHost host,
  }) => _call('resolveHostBindingV2', {
    'schemaVersion': 2,
    'requestId': _identity(requestId),
    'authority': authority.toJson(),
    'hostId': host.id,
    'expectedHostRevision': host.revision,
    'expectedPairingRevision': host.pairingRevision,
    'expectedCatalogRevision': host.catalogRevision,
  }, (raw) => _resolvedHostBinding(raw, requestId, host.id));

  @override
  Future<AndroidGameStreamPolicyReceipt> configurePolicy({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required int expectedPolicyRevision,
    required AndroidGameStreamPolicyDraft policy,
  }) => _call(
    'configureStreamPolicyV2',
    {
      'schemaVersion': 2,
      'requestId': _identity(requestId),
      'authority': authority.toJson(),
      'expectedPolicyRevision': expectedPolicyRevision == 0
          ? 0
          : _revision(expectedPolicyRevision),
      'policy': policy.toJson(),
    },
    (raw) {
      final value = _exactMap(raw, {
        'schemaVersion',
        'requestId',
        'policyId',
        'policyRevision',
      });
      if (value['schemaVersion'] != 2 || value['requestId'] != requestId) {
        throw const GameStreamException('invalid_native_receipt');
      }
      return AndroidGameStreamPolicyReceipt._(
        requestId: requestId,
        policyId: _identity(value['policyId']),
        policyRevision: _revision(value['policyRevision']),
      );
    },
  );

  @override
  Future<AndroidGameStreamCatalogReceipt> readCatalog({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamHostBinding binding,
    required CoreGameStreamHost host,
    required CoreGameStreamCatalogIntent intent,
  }) {
    final grant = intent.catalogGrant;
    if (grant == null || intent.hostId != host.id) {
      throw const GameStreamException('catalog_reconcile_required');
    }
    return _call('readCatalogV2', {
      'schemaVersion': 2,
      'requestId': _identity(requestId),
      'authority': authority.toJson(),
      'nativeBindingId': binding.nativeBindingId,
      'expectedBindingRevision': binding.bindingRevision,
      'hostId': host.id,
      'expectedHostRevision': host.revision,
      'expectedPairingRevision': host.pairingRevision,
      'expectedCatalogRevision': host.catalogRevision,
      'catalogObservationId': intent.id,
      'expectedObservationRevision': intent.revision,
      'catalogGrant': grant,
      'expiresAt': intent.expiresAt.millisecondsSinceEpoch / 1000,
    }, (raw) => _catalogReceipt(raw, requestId, intent.id));
  }

  @override
  Future<AndroidGameStreamRegistrationReceipt> commitCatalogRegistration({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamHostBinding binding,
    required CoreGameStreamCatalogUpdate update,
  }) => _call('commitRegistrationV2', {
    'schemaVersion': 2,
    'requestId': _identity(requestId),
    'authority': authority.toJson(),
    'nativeBindingId': binding.nativeBindingId,
    'expectedBindingRevision': binding.bindingRevision,
    'nativeReceiptId': update.nativeReceiptId,
    'host': {
      'id': update.hostId,
      'revision': update.hostRevision,
      'pairingRevision': update.pairingRevision,
      'catalogRevision': update.catalogRevision,
    },
    'apps': update.mapping
        .map(
          (item) => {
            'entryIndex': item.entryIndex,
            'id': item.app.id,
            'revision': item.app.revision,
          },
        )
        .toList(growable: false),
  }, (raw) => _catalogRegistrationReceipt(raw, requestId, update));

  @override
  Future<AndroidGameStreamCatalogReceipt?> reconcileCatalog({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required String catalogObservationId,
  }) => _reconcile(
    requestId: requestId,
    authority: authority,
    operationKind: 'catalog',
    operationId: catalogObservationId,
    parse: (raw) => _catalogReceipt(raw, requestId, catalogObservationId),
  );

  @override
  Future<AndroidGameStreamSessionCapabilities> sessionCapabilities({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required CoreGameStreamHost host,
    required CoreGameStreamApp app,
  }) => _call('sessionCapabilitiesV2', {
    'schemaVersion': 2,
    'requestId': _identity(requestId),
    'authority': authority.toJson(),
    'hostId': host.id,
    'expectedHostRevision': host.revision,
    'expectedPairingRevision': host.pairingRevision,
    'expectedCatalogRevision': host.catalogRevision,
    'appId': app.id,
    'expectedAppRevision': app.revision,
  }, (raw) => _sessionCapabilities(raw, requestId));

  @override
  Future<void> bindSession({
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamResolvedBinding binding,
    required CoreGameStreamSession session,
    required CoreGameStreamSelectedQuality selectedQuality,
  }) => _call(
    'bindSessionV2',
    {
      'schemaVersion': 2,
      'authority': authority.toJson(),
      'nativeBindingId': binding.nativeBindingId,
      'expectedBindingRevision': binding.bindingRevision,
      'registrationRevision': binding.registrationRevision,
      'sessionId': session.id,
      'sessionRevision': session.revision,
      'hostId': session.hostId,
      'hostRevision': session.hostRevision,
      'pairingRevision': session.pairingRevision,
      'catalogRevision': session.catalogRevision,
      'appId': session.appId,
      'appRevision': session.appRevision,
      'expiresAt': session.expiresAt.millisecondsSinceEpoch / 1000,
      'selectedQuality': selectedQuality.toJson(),
    },
    (raw) {
      if (raw != null) {
        throw const GameStreamException('invalid_native_receipt');
      }
    },
  );

  @override
  Future<AndroidGameStreamCommandReceiptV2> executeV2({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required CoreGameStreamSession session,
    required CoreGameStreamAuthorization authorization,
    AndroidGameStreamResolvedBinding? safetyClosure,
  }) {
    final grant = authorization.dispatchGrant;
    if (grant == null || authorization.command.state != 'authorized') {
      throw const GameStreamException('command_reconcile_required');
    }
    final stop = authorization.command.intent == 'stop';
    if (stop != (safetyClosure != null)) {
      throw const GameStreamException('invalid_safety_closure');
    }
    return _call(
      'executeV2',
      {
        'schemaVersion': 2,
        'requestId': _identity(requestId),
        'authority': authority.toJson(),
        'sessionId': session.id,
        'expectedSessionRevision': session.revision,
        'command': {
          'id': authorization.command.id,
          'intent': authorization.command.intent,
        },
        'dispatchGrant': grant,
        if (safetyClosure != null)
          'safetyClosure': {
            'nativeBindingId': safetyClosure.nativeBindingId,
            'bindingRevision': safetyClosure.bindingRevision,
          },
      },
      (raw) =>
          _commandReceipt(raw, requestId, session.id, authorization.command),
    );
  }

  @override
  Future<AndroidGameStreamCommandReceiptV2?> reconcileCommand({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required String commandId,
  }) => _reconcile(
    requestId: requestId,
    authority: authority,
    operationKind: 'command',
    operationId: commandId,
    parse: (raw) {
      final parsed = _commandReceiptLoose(raw, requestId);
      if (parsed.commandId != commandId) {
        throw const GameStreamException('invalid_native_receipt');
      }
      return parsed;
    },
  );

  @override
  Future<AndroidGameStreamForegroundCoverageReceipt> foregroundLease({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamResolvedBinding binding,
    required CoreGameStreamSession session,
  }) => _call('foregroundLeaseV2', {
    'schemaVersion': 2,
    'requestId': _identity(requestId),
    'authority': authority.toJson(),
    'nativeBindingId': binding.nativeBindingId,
    'expectedBindingRevision': binding.bindingRevision,
    'sessionId': session.id,
    'expectedSessionRevision': session.revision,
  }, (raw) => _foregroundLease(raw, requestId, binding, session));

  @override
  Future<AndroidGameStreamForegroundCoverageReceipt> pairingPrompt({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required AndroidGameStreamDiscovery discovery,
    required CoreGameStreamPairingIntent intent,
  }) => _call('pairingPromptV2', {
    'schemaVersion': 2,
    'requestId': _identity(requestId),
    'authority': authority.toJson(),
    'nativeBindingId': discovery.nativeBindingId,
    'expectedBindingRevision': discovery.bindingRevision,
    'pairingId': intent.id,
    'expectedPairingRevision': intent.revision,
  }, (raw) => _pairingPrompt(raw, requestId, discovery, intent));

  @override
  Future<AndroidGameStreamRevocationReceipt?> reconcileRevocation({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required String revocationId,
  }) => _reconcile(
    requestId: requestId,
    authority: authority,
    operationKind: 'revoke',
    operationId: revocationId,
    parse: (raw) => _revocationReceipt(raw, requestId, revocationId),
  );

  @override
  Future<AndroidGameStreamRevocationReceipt> revokePairing({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required CoreGameStreamRevocation revocation,
    required CoreGameStreamHost host,
  }) => _call('revokePairingV2', {
    'schemaVersion': 2,
    'requestId': _identity(requestId),
    'authority': authority.toJson(),
    'revocationId': revocation.id,
    'hostId': host.id,
    'expectedHostRevision': host.revision,
    'expectedPairingRevision': host.pairingRevision,
    'expectedCatalogRevision': host.catalogRevision,
  }, (raw) => _revocationReceipt(raw, requestId, revocation.id));

  @override
  Future<AndroidGameStreamAuthorityRetirementReceipt> retireAuthority({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    String? nativeBindingId,
    int? bindingRevision,
  }) {
    if ((nativeBindingId == null) != (bindingRevision == null)) {
      throw const GameStreamException('invalid_native_binding');
    }
    final exactRequestId = _identity(requestId);
    final exactBindingId = nativeBindingId == null
        ? null
        : _identity(nativeBindingId);
    final exactBindingRevision = bindingRevision == null
        ? null
        : _revision(bindingRevision);
    return _call(
      'retireAuthorityV2',
      {
        'schemaVersion': 2,
        'requestId': exactRequestId,
        'authority': authority.toJson(),
        'nativeBindingId': exactBindingId,
        'bindingRevision': exactBindingRevision,
      },
      (raw) {
        final value = _exactMap(raw, {
          'schemaVersion',
          'requestId',
          'authorityId',
          'authorityEpoch',
          'nativeBindingId',
          'bindingRevision',
          'state',
        });
        if (value['schemaVersion'] != 2 ||
            value['requestId'] != exactRequestId ||
            value['state'] != 'retired' ||
            (exactBindingId != null &&
                value['nativeBindingId'] != exactBindingId) ||
            (exactBindingRevision != null &&
                value['bindingRevision'] != exactBindingRevision)) {
          throw const GameStreamException('invalid_native_receipt');
        }
        return AndroidGameStreamAuthorityRetirementReceipt._(
          requestId: exactRequestId,
          authorityId: _identity(value['authorityId']),
          authorityEpoch: _revision(value['authorityEpoch']),
          nativeBindingId: _identity(value['nativeBindingId']),
          bindingRevision: _revision(value['bindingRevision']),
        );
      },
    );
  }

  Future<T?> _reconcile<T>({
    required String requestId,
    required AndroidGameStreamAuthorityV2 authority,
    required String operationKind,
    required String operationId,
    required T Function(Object?) parse,
  }) => _call(
    'reconcileV2',
    {
      'schemaVersion': 2,
      'requestId': _identity(requestId),
      'authority': authority.toJson(),
      'operationKind': operationKind,
      'operationId': _identity(operationId),
    },
    (raw) {
      final value = _exactMap(raw, {
        'schemaVersion',
        'requestId',
        'operationKind',
        'terminal',
        'receipt',
      });
      if (value['schemaVersion'] != 2 ||
          value['requestId'] != requestId ||
          value['operationKind'] != operationKind ||
          value['terminal'] is! bool ||
          (value['terminal'] == false && value['receipt'] != null) ||
          (value['terminal'] == true && value['receipt'] == null)) {
        throw const GameStreamException('invalid_native_receipt');
      }
      final receipt = value['receipt'];
      return receipt == null ? null : parse(receipt);
    },
  );

  @override
  Future<void> retireV2({required String sessionId, required int epoch}) async {
    retireLocally();
    final exactSessionId = _identity(sessionId);
    final exactEpoch = _revision(epoch);
    final value = _exactMap(
      await _channel.invokeMethod<Object?>('retire', {
        'sessionId': exactSessionId,
        'epoch': exactEpoch,
      }),
      {'schemaVersion', 'sessionId', 'epoch', 'state'},
    );
    if (value['schemaVersion'] != 2 ||
        value['sessionId'] != exactSessionId ||
        value['epoch'] != exactEpoch ||
        value['state'] != 'retired') {
      throw const GameStreamException('invalid_native_receipt');
    }
  }
}

AndroidGameStreamDiscovery _discovery(Object? raw, String requestId) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'nativeBindingId',
    'bindingRevision',
    'engineRevision',
    'provider',
    'catalogRevision',
    'catalogDigest',
    'candidates',
  });
  final rawCandidates = value['candidates'];
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      value['provider'] != 'moonlight-nvhttp' ||
      rawCandidates is! List ||
      rawCandidates.length > 64) {
    throw const GameStreamException('invalid_native_receipt');
  }
  final candidates = <AndroidGameStreamCandidate>[];
  for (final rawCandidate in rawCandidates) {
    final item = _exactMap(rawCandidate, {
      'candidateId',
      'revision',
      'name',
      'powerState',
      'pairState',
    });
    if (!{'awake', 'asleep', 'unknown'}.contains(item['powerState']) ||
        !{'paired', 'notPaired', 'unknown'}.contains(item['pairState'])) {
      throw const GameStreamException('invalid_native_receipt');
    }
    candidates.add(
      AndroidGameStreamCandidate._(
        id: _identity(item['candidateId']),
        revision: _revision(item['revision']),
        name: _text(item['name'], 80),
        powerState: item['powerState']! as String,
        pairState: item['pairState']! as String,
      ),
    );
  }
  if (candidates.map((item) => item.id).toSet().length != candidates.length) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamDiscovery._(
    requestId: requestId,
    nativeBindingId: _identity(value['nativeBindingId']),
    bindingRevision: _revision(value['bindingRevision']),
    engineRevision: _engineRevision(value['engineRevision']),
    catalogRevision: _revision(value['catalogRevision']),
    catalogDigest: _digest(value['catalogDigest']),
    candidates: List.unmodifiable(candidates),
  );
}

AndroidGameStreamPairingReceipt _pairingReceipt(
  Object? raw,
  String requestId,
  String pairingId,
) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'pairingId',
    'state',
    'nativeReceiptDigest',
    'observation',
  });
  final state = value['state'];
  final observation = value['observation'];
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      value['pairingId'] != pairingId ||
      !{'paired', 'rejected', 'unknown'}.contains(state) ||
      (state == 'paired') != (observation != null)) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamPairingReceipt._(
    requestId: requestId,
    pairingId: pairingId,
    state: state! as String,
    nativeReceiptDigest: _digest(value['nativeReceiptDigest']),
    observation: observation == null ? null : _pairObservation(observation),
  );
}

AndroidGameStreamCatalogReceipt _catalogReceipt(
  Object? raw,
  String requestId,
  String catalogObservationId,
) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'catalogObservationId',
    'state',
    'nativeReceiptDigest',
    'observation',
  });
  final state = value['state'];
  final observation = value['observation'];
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      value['catalogObservationId'] != catalogObservationId ||
      !{'observed', 'unknown'}.contains(state) ||
      (state == 'observed') != (observation != null)) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamCatalogReceipt._(
    requestId: requestId,
    catalogObservationId: catalogObservationId,
    state: state! as String,
    nativeReceiptDigest: _digest(value['nativeReceiptDigest']),
    observation: observation == null ? null : _catalogObservation(observation),
  );
}

CoreNativeCatalogObservation _catalogObservation(Object? raw) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'receiptId',
    'nativeBindingId',
    'bindingRevision',
    'catalogRevision',
    'catalogDigest',
    'apps',
  });
  final rawApps = value['apps'];
  if (value['schemaVersion'] != 1 || rawApps is! List || rawApps.length > 256) {
    throw const GameStreamException('invalid_native_receipt');
  }
  final apps = <CoreNativeAppObservation>[];
  for (final rawApp in rawApps) {
    final app = _exactMap(rawApp, {'observationId', 'revision', 'name'});
    apps.add(
      CoreNativeAppObservation(
        observationId: _identity(app['observationId']),
        revision: _revision(app['revision']),
        name: _text(app['name'], 160),
      ),
    );
  }
  if (apps.map((item) => item.observationId).toSet().length != apps.length) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return CoreNativeCatalogObservation(
    receiptId: _identity(value['receiptId']),
    nativeBindingId: _identity(value['nativeBindingId']),
    bindingRevision: _revision(value['bindingRevision']),
    catalogRevision: _revision(value['catalogRevision']),
    catalogDigest: _digest(value['catalogDigest']),
    apps: List.unmodifiable(apps),
  );
}

CoreNativePairingObservation _pairObservation(Object? raw) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'receiptId',
    'nativeBindingId',
    'bindingRevision',
    'engineRevision',
    'provider',
    'state',
    'hostObservationId',
    'name',
    'codecs',
    'catalogRevision',
    'catalogDigest',
    'apps',
  });
  final rawCodecs = value['codecs'];
  final rawApps = value['apps'];
  if (value['schemaVersion'] != 1 ||
      value['provider'] != 'moonlight-nvhttp' ||
      value['state'] != 'paired' ||
      rawCodecs is! List ||
      rawCodecs.isEmpty ||
      rawCodecs.length > 3 ||
      rawApps is! List ||
      rawApps.length > 256) {
    throw const GameStreamException('invalid_native_receipt');
  }
  final codecs = <String>[];
  for (final codec in rawCodecs) {
    if (codec is! String ||
        !{'h264', 'hevc', 'av1'}.contains(codec) ||
        codecs.contains(codec)) {
      throw const GameStreamException('invalid_native_receipt');
    }
    codecs.add(codec);
  }
  final apps = <CoreNativeAppObservation>[];
  for (final rawApp in rawApps) {
    final app = _exactMap(rawApp, {'observationId', 'revision', 'name'});
    apps.add(
      CoreNativeAppObservation(
        observationId: _identity(app['observationId']),
        revision: _revision(app['revision']),
        name: _text(app['name'], 160),
      ),
    );
  }
  if (apps.map((item) => item.observationId).toSet().length != apps.length) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return CoreNativePairingObservation(
    receiptId: _identity(value['receiptId']),
    nativeBindingId: _identity(value['nativeBindingId']),
    bindingRevision: _revision(value['bindingRevision']),
    engineRevision: _engineRevision(value['engineRevision']),
    hostObservationId: _identity(value['hostObservationId']),
    name: _text(value['name'], 80),
    codecs: List.unmodifiable(codecs),
    catalogRevision: _revision(value['catalogRevision']),
    catalogDigest: _digest(value['catalogDigest']),
    apps: List.unmodifiable(apps),
  );
}

AndroidGameStreamRegistrationReceipt _registrationReceipt(
  Object? raw,
  String requestId,
  CoreGameStreamRegistration registration,
) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'registrationRevision',
    'hostId',
    'appIds',
    'nativeReceiptDigest',
  });
  final rawApps = value['appIds'];
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      value['hostId'] != registration.host.id ||
      rawApps is! List ||
      rawApps.length != registration.apps.length) {
    throw const GameStreamException('invalid_native_receipt');
  }
  final appIds = rawApps.map(_identity).toList(growable: false);
  if (appIds.toSet().length != appIds.length ||
      appIds
          .toSet()
          .difference(registration.apps.map((item) => item.id).toSet())
          .isNotEmpty) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamRegistrationReceipt._(
    requestId: requestId,
    registrationRevision: _revision(value['registrationRevision']),
    hostId: registration.host.id,
    appIds: List.unmodifiable(appIds),
    nativeReceiptDigest: _digest(value['nativeReceiptDigest']),
  );
}

AndroidGameStreamRegistrationReceipt _catalogRegistrationReceipt(
  Object? raw,
  String requestId,
  CoreGameStreamCatalogUpdate update,
) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'registrationRevision',
    'hostId',
    'appIds',
    'nativeReceiptDigest',
  });
  final rawApps = value['appIds'];
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      value['hostId'] != update.hostId ||
      rawApps is! List ||
      rawApps.length != update.apps.length) {
    throw const GameStreamException('invalid_native_receipt');
  }
  final appIds = rawApps.map(_identity).toList(growable: false);
  if (appIds.toSet().length != appIds.length ||
      appIds
          .toSet()
          .difference(update.apps.map((item) => item.id).toSet())
          .isNotEmpty) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamRegistrationReceipt._(
    requestId: requestId,
    registrationRevision: _revision(value['registrationRevision']),
    hostId: update.hostId,
    appIds: List.unmodifiable(appIds),
    nativeReceiptDigest: _digest(value['nativeReceiptDigest']),
  );
}

AndroidGameStreamResolvedBinding _resolvedBinding(
  Object? raw,
  String requestId,
  String hostId,
  String appId,
) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'nativeBindingId',
    'bindingRevision',
    'registrationRevision',
    'hostId',
    'appId',
    'engineRevision',
  });
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      value['hostId'] != hostId ||
      value['appId'] != appId) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamResolvedBinding._(
    requestId: requestId,
    nativeBindingId: _identity(value['nativeBindingId']),
    bindingRevision: _revision(value['bindingRevision']),
    registrationRevision: _revision(value['registrationRevision']),
    hostId: hostId,
    appId: appId,
    engineRevision: _engineRevision(value['engineRevision']),
  );
}

AndroidGameStreamHostBinding _resolvedHostBinding(
  Object? raw,
  String requestId,
  String hostId,
) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'nativeBindingId',
    'bindingRevision',
    'registrationRevision',
    'hostId',
    'engineRevision',
  });
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      value['hostId'] != hostId) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamHostBinding._(
    nativeBindingId: _identity(value['nativeBindingId']),
    bindingRevision: _revision(value['bindingRevision']),
    registrationRevision: _revision(value['registrationRevision']),
    hostId: hostId,
    engineRevision: _engineRevision(value['engineRevision']),
  );
}

AndroidGameStreamSessionCapabilities _sessionCapabilities(
  Object? raw,
  String requestId,
) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'availability',
    'reason',
    'display',
    'network',
    'decoders',
    'policy',
    'qualityOptions',
  });
  final available = value['availability'] == 'available';
  final reason = value['reason'];
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      (!available && value['availability'] != 'unavailable') ||
      (available
          ? reason != null
          : !{
              'displayUnavailable',
              'networkUnavailable',
              'policyUnavailable',
              'codecUnavailable',
              'meteredDenied',
              'queuePolicyUnsupported',
            }.contains(reason))) {
    throw const GameStreamException('invalid_native_receipt');
  }
  final display = value['display'] == null ? null : _display(value['display']);
  final network = value['network'] == null ? null : _network(value['network']);
  final policy = value['policy'] == null ? null : _policy(value['policy']);
  final rawDecoders = value['decoders'];
  final rawOptions = value['qualityOptions'];
  if (rawDecoders is! List ||
      rawDecoders.length > 3 ||
      rawOptions is! List ||
      rawOptions.length > 24) {
    throw const GameStreamException('invalid_native_receipt');
  }
  final decoders = rawDecoders.map(_decoder).toList(growable: false);
  final options = rawOptions.map(_qualityOption).toList(growable: false);
  if (available &&
      (display == null ||
          !display.attached ||
          !display.secureSurface ||
          network == null ||
          network.reachability == 'unavailable' ||
          policy == null ||
          options.isEmpty)) {
    throw const GameStreamException('invalid_native_receipt');
  }
  if (!available && options.isNotEmpty) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamSessionCapabilities._(
    requestId: requestId,
    available: available,
    reason: reason as String?,
    display: display,
    network: network,
    decoders: List.unmodifiable(decoders),
    policy: policy,
    qualityOptions: List.unmodifiable(options),
  );
}

AndroidGameStreamDisplayObservation _display(Object? raw) {
  final value = _exactMap(raw, {
    'displayId',
    'displayRevision',
    'attached',
    'widthPixels',
    'heightPixels',
    'densityDpi',
    'secureSurface',
    'maxRefreshRate',
  });
  if (value['attached'] is! bool || value['secureSurface'] is! bool) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamDisplayObservation._(
    id: _integer(value['displayId'], 0, 63),
    revision: _revision(value['displayRevision']),
    attached: value['attached']! as bool,
    widthPixels: _integer(value['widthPixels'], 1, 16384),
    heightPixels: _integer(value['heightPixels'], 1, 16384),
    densityDpi: _integer(value['densityDpi'], 72, 1280),
    secureSurface: value['secureSurface']! as bool,
    maxRefreshRate: _integer(value['maxRefreshRate'], 1, 240),
  );
}

AndroidGameStreamNetworkObservation _network(Object? raw) {
  final value = _exactMap(raw, {
    'networkId',
    'networkRevision',
    'reachability',
    'metered',
  });
  if (!{'local', 'remote', 'unavailable'}.contains(value['reachability']) ||
      value['metered'] is! bool) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamNetworkObservation._(
    id: _identity(value['networkId']),
    revision: _revision(value['networkRevision']),
    reachability: value['reachability']! as String,
    metered: value['metered']! as bool,
  );
}

AndroidGameStreamDecoderObservation _decoder(Object? raw) {
  final value = _exactMap(raw, {
    'codecId',
    'codecRevision',
    'codec',
    'supported',
    'maxWidthPixels',
    'maxHeightPixels',
    'maxFramesPerSecond',
  });
  if (!{'h264', 'hevc', 'av1'}.contains(value['codec']) ||
      value['supported'] is! bool) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamDecoderObservation._(
    id: _identity(value['codecId']),
    revision: _revision(value['codecRevision']),
    codec: value['codec']! as String,
    supported: value['supported']! as bool,
    maxWidthPixels: _integer(value['maxWidthPixels'], 320, 8192),
    maxHeightPixels: _integer(value['maxHeightPixels'], 320, 8192),
    maxFramesPerSecond: _integer(value['maxFramesPerSecond'], 24, 240),
  );
}

AndroidGameStreamPolicyObservation _policy(Object? raw) {
  final value = _exactMap(raw, {
    'policyId',
    'policyRevision',
    'allowedCodecIds',
    'allowMetered',
    'requirePin',
    'maxWidth',
    'maxHeight',
    'maxFps',
    'maxBitrateKbps',
    'maximumIdleSeconds',
    'maximumSessionSeconds',
    'frameQueueDepth',
    'inputQueueDepth',
  });
  final rawIds = value['allowedCodecIds'];
  if (rawIds is! List ||
      rawIds.isEmpty ||
      rawIds.length > 3 ||
      value['allowMetered'] is! bool ||
      value['requirePin'] is! bool) {
    throw const GameStreamException('invalid_native_receipt');
  }
  final ids = rawIds.map(_identity).toList(growable: false);
  if (ids.toSet().length != ids.length) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamPolicyObservation._(
    id: _identity(value['policyId']),
    revision: _revision(value['policyRevision']),
    allowedCodecIds: List.unmodifiable(ids),
    allowMetered: value['allowMetered']! as bool,
    requirePin: value['requirePin']! as bool,
    maxWidth: _integer(value['maxWidth'], 320, 8192),
    maxHeight: _integer(value['maxHeight'], 320, 8192),
    maxFps: _integer(value['maxFps'], 24, 240),
    maxBitrateKbps: _integer(value['maxBitrateKbps'], 2000, 100000),
    maximumIdleSeconds: _integer(value['maximumIdleSeconds'], 30, 3600),
    maximumSessionSeconds: _integer(value['maximumSessionSeconds'], 60, 3600),
    frameQueueDepth: _integer(value['frameQueueDepth'], 1, 3),
    inputQueueDepth: _integer(value['inputQueueDepth'], 1, 32),
  );
}

AndroidGameStreamQualityOption _qualityOption(Object? raw) {
  final value = _exactMap(raw, {
    'codec',
    'codecId',
    'codecRevision',
    'displayId',
    'displayRevision',
    'networkId',
    'networkRevision',
    'policyId',
    'policyRevision',
    'widthPixels',
    'heightPixels',
    'framesPerSecond',
    'bitrateKbps',
    'frameQueueDepth',
    'inputQueueDepth',
    'secureSurface',
  });
  if (value['secureSurface'] != true) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamQualityOption._(
    selectedQuality: CoreGameStreamSelectedQuality(
      codec: _codec(value['codec']),
      codecId: _identity(value['codecId']),
      codecRevision: _revision(value['codecRevision']),
      displayId: _integer(value['displayId'], 0, 63),
      displayRevision: _revision(value['displayRevision']),
      networkId: _identity(value['networkId']),
      networkRevision: _revision(value['networkRevision']),
      policyId: _identity(value['policyId']),
      policyRevision: _revision(value['policyRevision']),
      widthPixels: _integer(value['widthPixels'], 320, 8192),
      heightPixels: _integer(value['heightPixels'], 320, 8192),
      framesPerSecond: _integer(value['framesPerSecond'], 24, 120),
      bitrateKbps: _integer(value['bitrateKbps'], 2000, 100000),
      frameQueueDepth: _integer(value['frameQueueDepth'], 1, 3),
      inputQueueDepth: _integer(value['inputQueueDepth'], 1, 32),
    ),
  );
}

AndroidGameStreamCommandReceiptV2 _commandReceipt(
  Object? raw,
  String requestId,
  String sessionId,
  CoreGameStreamCommand command,
) {
  final receipt = _commandReceiptLoose(raw, requestId);
  if (receipt.sessionId != sessionId ||
      receipt.commandId != command.id ||
      !_receiptMatchesIntent(receipt, command.intent)) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return receipt;
}

AndroidGameStreamCommandReceiptV2 _commandReceiptLoose(
  Object? raw,
  String requestId,
) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'sessionId',
    'commandId',
    'state',
    'result',
    'observationKind',
    'readbackRevision',
    'nativeReceiptDigest',
  });
  final state = value['state'];
  final result = value['result'];
  final observation = value['observationKind'];
  final revision = value['readbackRevision'];
  final digest = value['nativeReceiptDigest'];
  final terminalValid = switch (state) {
    'native_observed' => revision != null && digest != null,
    'rejected' =>
      result == 'rejected' &&
          observation == 'nativeRejected' &&
          revision != null &&
          digest != null,
    'unknown' =>
      result == 'unknown' &&
          observation == 'unknown' &&
          revision == null &&
          digest == null,
    _ => false,
  };
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      !terminalValid) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamCommandReceiptV2._(
    requestId: requestId,
    sessionId: _identity(value['sessionId']),
    commandId: _identity(value['commandId']),
    state: state! as String,
    result: result! as String,
    observationKind: observation! as String,
    readbackRevision: revision == null ? null : _revision(revision),
    nativeReceiptDigest: digest == null ? null : _digest(digest),
  );
}

AndroidGameStreamForegroundCoverageReceipt _foregroundLease(
  Object? raw,
  String requestId,
  AndroidGameStreamResolvedBinding binding,
  CoreGameStreamSession session,
) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'nativeBindingId',
    'bindingRevision',
    'sessionId',
    'sessionRevision',
    'owned',
    'state',
  });
  final owned = value['owned'];
  final state = value['state'];
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      value['nativeBindingId'] != binding.nativeBindingId ||
      value['bindingRevision'] != binding.bindingRevision ||
      value['sessionId'] != session.id ||
      value['sessionRevision'] != session.revision ||
      owned is! bool ||
      !{'transfer_pending', 'game_visible', 'unavailable'}.contains(state) ||
      owned != {'transfer_pending', 'game_visible'}.contains(state)) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamForegroundCoverageReceipt._(
    coverage: owned
        ? AndroidGameStreamForegroundCoverage.game
        : AndroidGameStreamForegroundCoverage.unavailable,
    state: state! as String,
  );
}

AndroidGameStreamForegroundCoverageReceipt _pairingPrompt(
  Object? raw,
  String requestId,
  AndroidGameStreamDiscovery discovery,
  CoreGameStreamPairingIntent intent,
) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'nativeBindingId',
    'bindingRevision',
    'pairingId',
    'pairingRevision',
    'owned',
    'state',
  });
  final owned = value['owned'];
  final state = value['state'];
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      value['nativeBindingId'] != discovery.nativeBindingId ||
      value['bindingRevision'] != discovery.bindingRevision ||
      value['pairingId'] != intent.id ||
      value['pairingRevision'] != intent.revision ||
      owned is! bool ||
      !{'pairing_prompt', 'unavailable'}.contains(state) ||
      owned != (state == 'pairing_prompt')) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamForegroundCoverageReceipt._(
    coverage: owned
        ? AndroidGameStreamForegroundCoverage.pairingPrompt
        : AndroidGameStreamForegroundCoverage.unavailable,
    state: state! as String,
  );
}

AndroidGameStreamRevocationReceipt _revocationReceipt(
  Object? raw,
  String requestId,
  String revocationId,
) {
  final value = _exactMap(raw, {
    'schemaVersion',
    'requestId',
    'revocationId',
    'state',
    'readbackRevision',
    'nativeReceiptDigest',
  });
  if (value['schemaVersion'] != 2 ||
      value['requestId'] != requestId ||
      value['revocationId'] != revocationId ||
      !{'local_cleared', 'unknown'}.contains(value['state']) ||
      (value['state'] == 'local_cleared' &&
          (value['readbackRevision'] == null ||
              value['nativeReceiptDigest'] == null)) ||
      (value['state'] == 'unknown' &&
          (value['readbackRevision'] != null ||
              value['nativeReceiptDigest'] != null))) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return AndroidGameStreamRevocationReceipt._(
    requestId: requestId,
    revocationId: revocationId,
    state: value['state']! as String,
    readbackRevision: value['readbackRevision'] == null
        ? null
        : _revision(value['readbackRevision']),
    nativeReceiptDigest: value['nativeReceiptDigest'] == null
        ? null
        : _digest(value['nativeReceiptDigest']),
  );
}

bool _receiptMatchesIntent(
  AndroidGameStreamCommandReceiptV2 receipt,
  String intent,
) {
  if (receipt.state == 'unknown' || receipt.state == 'rejected') return true;
  if (intent == 'stop') {
    return receipt.result == 'stopped' &&
        {
          'connectionStopped',
          'connectionTerminated',
        }.contains(receipt.observationKind);
  }
  final expected = switch (intent) {
    'wake' => ('hostAwake', 'serverInfoOnline'),
    'launch' => ('appRunning', 'currentGameMatched'),
    'stream' => ('streaming', 'connectionStarted'),
    _ => (null, null),
  };
  return receipt.result == expected.$1 &&
      receipt.observationKind == expected.$2;
}

Map<String, dynamic> _exactMap(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.keys.any((key) => key is! String) ||
      raw.length != keys.length ||
      !raw.keys.every(keys.contains)) {
    throw const GameStreamException('invalid_native_receipt');
  }
  return raw.cast<String, dynamic>();
}

String _identity(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
    ? value
    : throw const GameStreamException('invalid_native_receipt');

int _revision(Object? value) =>
    value is int && value >= 1 && value <= gameStreamMaxSafeInteger
    ? value
    : throw const GameStreamException('invalid_native_receipt');

int _integer(Object? value, int min, int max) =>
    value is int && value >= min && value <= max
    ? value
    : throw const GameStreamException('invalid_native_receipt');

String _text(Object? value, int max) =>
    value is String &&
        value.trim() == value &&
        value.isNotEmpty &&
        value.length <= max &&
        !value.contains(RegExp(r'[\x00-\x1f\x7f]'))
    ? value
    : throw const GameStreamException('invalid_native_receipt');

String _digest(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value)
    ? value
    : throw const GameStreamException('invalid_native_receipt');

String _engineRevision(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(value)
    ? value
    : throw const GameStreamException('invalid_native_receipt');

String _codec(Object? value) =>
    value is String && {'h264', 'hevc', 'av1'}.contains(value)
    ? value
    : throw const GameStreamException('invalid_native_receipt');
