import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';

const int gameStreamMaxSafeInteger = 9007199254740991;

final class CoreGameStreamHost {
  CoreGameStreamHost._({
    required this.id,
    required this.revision,
    required this.pairingRevision,
    required this.catalogRevision,
    required this.name,
    required this.codecs,
  });

  factory CoreGameStreamHost.fromJson(Object? raw) {
    final value = _exactMap(raw, {
      'schemaVersion',
      'id',
      'revision',
      'pairingRevision',
      'catalogRevision',
      'name',
      'assurance',
      'active',
      'codecs',
    });
    final rawCodecs = value['codecs'];
    if (value['schemaVersion'] != 2 ||
        value['assurance'] != 'native_observed' ||
        value['active'] != true ||
        rawCodecs is! List ||
        rawCodecs.isEmpty ||
        rawCodecs.length > 3) {
      throw const LarenorServerException('invalid_response');
    }
    final codecs = <String>[];
    for (final rawCodec in rawCodecs) {
      if (rawCodec is! String ||
          !{'h264', 'hevc', 'av1'}.contains(rawCodec) ||
          codecs.contains(rawCodec)) {
        throw const LarenorServerException('invalid_response');
      }
      codecs.add(rawCodec);
    }
    return CoreGameStreamHost._(
      id: _identity(value['id']),
      revision: _revision(value['revision']),
      pairingRevision: _revision(value['pairingRevision']),
      catalogRevision: _revision(value['catalogRevision']),
      name: _text(value['name'], 80),
      codecs: List.unmodifiable(codecs),
    );
  }

  factory CoreGameStreamHost.recovery({
    required String id,
    required int revision,
    required int pairingRevision,
    required int catalogRevision,
    required String name,
    required List<String> codecs,
  }) => CoreGameStreamHost.fromJson({
    'schemaVersion': 2,
    'id': id,
    'revision': revision,
    'pairingRevision': pairingRevision,
    'catalogRevision': catalogRevision,
    'name': name,
    'assurance': 'native_observed',
    'active': true,
    'codecs': codecs,
  });

  final String id, name;
  final int revision, pairingRevision, catalogRevision;
  final List<String> codecs;
}

final class CoreGameStreamApp {
  CoreGameStreamApp._({
    required this.id,
    required this.hostId,
    required this.revision,
    required this.name,
  });

  factory CoreGameStreamApp.fromJson(Object? raw, {required String hostId}) {
    final value = _exactMap(raw, {
      'schemaVersion',
      'id',
      'hostId',
      'revision',
      'name',
      'active',
    });
    if (value['schemaVersion'] != 2 ||
        value['hostId'] != hostId ||
        value['active'] != true) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamApp._(
      id: _identity(value['id']),
      hostId: hostId,
      revision: _revision(value['revision']),
      name: _text(value['name'], 160),
    );
  }

  final String id, hostId, name;
  final int revision;
}

final class CoreGameStreamHosts {
  const CoreGameStreamHosts({
    required this.accountRevision,
    required this.hosts,
  });

  final int accountRevision;
  final List<CoreGameStreamHost> hosts;
}

final class CoreGameStreamCatalog {
  const CoreGameStreamCatalog({required this.host, required this.apps});

  final CoreGameStreamHost host;
  final List<CoreGameStreamApp> apps;
}

final class CoreGameStreamPairingIntent {
  CoreGameStreamPairingIntent._({
    required this.id,
    required this.revision,
    required this.expiresAt,
    required this.pairingGrant,
  });

  factory CoreGameStreamPairingIntent.fromJson(Object? raw) {
    final value = _exactMap(raw, {
      'schemaVersion',
      'id',
      'revision',
      'state',
      'pairingGrant',
      'expiresAt',
    });
    final grant = value['pairingGrant'];
    if (value['schemaVersion'] != 2 ||
        value['state'] != 'pending' ||
        (grant != null && !_isIdentity(grant))) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamPairingIntent._(
      id: _identity(value['id']),
      revision: _revision(value['revision']),
      expiresAt: _epoch(value['expiresAt']),
      pairingGrant: grant as String?,
    );
  }

  factory CoreGameStreamPairingIntent.recovery({
    required String id,
    required int revision,
    required String pairingGrant,
    required DateTime expiresAt,
  }) => CoreGameStreamPairingIntent.fromJson({
    'schemaVersion': 2,
    'id': id,
    'revision': revision,
    'state': 'pending',
    'pairingGrant': pairingGrant,
    'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch / 1000,
  });

  final String id;
  final int revision;
  final DateTime expiresAt;

  /// Present only in the first successful create response. A null grant means
  /// the request was replayed and must never trigger native pairing I/O.
  final String? pairingGrant;
}

final class CoreGameStreamCatalogIntent {
  CoreGameStreamCatalogIntent._({
    required this.id,
    required this.hostId,
    required this.revision,
    required this.expiresAt,
    required this.catalogGrant,
  });

  factory CoreGameStreamCatalogIntent.fromJson(
    Object? raw, {
    required String hostId,
  }) {
    final value = _exactMap(raw, {
      'schemaVersion',
      'id',
      'hostId',
      'revision',
      'state',
      'catalogGrant',
      'expiresAt',
    });
    final grant = value['catalogGrant'];
    if (value['schemaVersion'] != 2 ||
        value['hostId'] != hostId ||
        value['state'] != 'pending' ||
        (grant != null && !_isIdentity(grant))) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamCatalogIntent._(
      id: _identity(value['id']),
      hostId: hostId,
      revision: _revision(value['revision']),
      expiresAt: _epoch(value['expiresAt']),
      catalogGrant: grant as String?,
    );
  }

  factory CoreGameStreamCatalogIntent.recovery({
    required String id,
    required String hostId,
    required int revision,
    required String catalogGrant,
    required DateTime expiresAt,
  }) => CoreGameStreamCatalogIntent.fromJson({
    'schemaVersion': 2,
    'id': id,
    'hostId': hostId,
    'revision': revision,
    'state': 'pending',
    'catalogGrant': catalogGrant,
    'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch / 1000,
  }, hostId: hostId);

  final String id, hostId;
  final int revision;
  final DateTime expiresAt;
  final String? catalogGrant;
}

final class CoreNativeAppObservation {
  const CoreNativeAppObservation({
    required this.observationId,
    required this.revision,
    required this.name,
  });

  final String observationId, name;
  final int revision;

  Map<String, Object> toJson() => {
    'observationId': observationId,
    'revision': revision,
    'name': name,
  };
}

final class CoreNativePairingObservation {
  const CoreNativePairingObservation({
    required this.receiptId,
    required this.nativeBindingId,
    required this.bindingRevision,
    required this.engineRevision,
    required this.hostObservationId,
    required this.name,
    required this.codecs,
    required this.catalogRevision,
    required this.catalogDigest,
    required this.apps,
  });

  final String receiptId, nativeBindingId, engineRevision;
  final String hostObservationId, name, catalogDigest;
  final int bindingRevision, catalogRevision;
  final List<String> codecs;
  final List<CoreNativeAppObservation> apps;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'receiptId': receiptId,
    'nativeBindingId': nativeBindingId,
    'bindingRevision': bindingRevision,
    'engineRevision': engineRevision,
    'provider': 'moonlight-nvhttp',
    'state': 'paired',
    'hostObservationId': hostObservationId,
    'name': name,
    'codecs': codecs,
    'catalogRevision': catalogRevision,
    'catalogDigest': catalogDigest,
    'apps': apps.map((item) => item.toJson()).toList(growable: false),
  };
}

final class CoreNativeCatalogObservation {
  const CoreNativeCatalogObservation({
    required this.receiptId,
    required this.nativeBindingId,
    required this.bindingRevision,
    required this.catalogRevision,
    required this.catalogDigest,
    required this.apps,
  });

  final String receiptId, nativeBindingId, catalogDigest;
  final int bindingRevision, catalogRevision;
  final List<CoreNativeAppObservation> apps;

  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'receiptId': receiptId,
    'nativeBindingId': nativeBindingId,
    'bindingRevision': bindingRevision,
    'catalogRevision': catalogRevision,
    'catalogDigest': catalogDigest,
    'apps': apps.map((item) => item.toJson()).toList(growable: false),
  };
}

final class CoreGameStreamRegistrationApp {
  const CoreGameStreamRegistrationApp({
    required this.entryIndex,
    required this.app,
  });

  final int entryIndex;
  final CoreGameStreamApp app;
}

final class CoreGameStreamRegistration {
  const CoreGameStreamRegistration({
    required this.host,
    required this.apps,
    required this.nativeReceiptId,
    required this.mapping,
  });

  final CoreGameStreamHost host;
  final List<CoreGameStreamApp> apps;
  final String nativeReceiptId;
  final List<CoreGameStreamRegistrationApp> mapping;
}

final class CoreGameStreamCatalogUpdate {
  const CoreGameStreamCatalogUpdate({
    required this.hostId,
    required this.hostRevision,
    required this.pairingRevision,
    required this.catalogRevision,
    required this.apps,
    required this.nativeReceiptId,
    required this.mapping,
  });

  final String hostId, nativeReceiptId;
  final int hostRevision, pairingRevision, catalogRevision;
  final List<CoreGameStreamApp> apps;
  final List<CoreGameStreamRegistrationApp> mapping;
}

final class CoreGameStreamClientAuthority {
  const CoreGameStreamClientAuthority({
    required this.routeRevision,
    required this.lifecycleRevision,
    required this.displayRevision,
    required this.networkRevision,
    required this.policyRevision,
  });

  final int routeRevision, lifecycleRevision;
  final int displayRevision, networkRevision, policyRevision;

  Map<String, int> toJson() => {
    'routeRevision': _checkedRevision(routeRevision),
    'lifecycleRevision': _checkedRevision(lifecycleRevision),
    'displayRevision': _checkedRevision(displayRevision),
    'networkRevision': _checkedRevision(networkRevision),
    'policyRevision': _checkedRevision(policyRevision),
  };
}

final class CoreGameStreamSelectedQuality {
  const CoreGameStreamSelectedQuality({
    required this.codec,
    required this.codecId,
    required this.codecRevision,
    required this.displayId,
    required this.displayRevision,
    required this.networkId,
    required this.networkRevision,
    required this.policyId,
    required this.policyRevision,
    required this.widthPixels,
    required this.heightPixels,
    required this.framesPerSecond,
    required this.bitrateKbps,
    required this.frameQueueDepth,
    required this.inputQueueDepth,
  });

  final String codec, codecId, networkId, policyId;
  final int codecRevision, displayId, displayRevision;
  final int networkRevision, policyRevision;
  final int widthPixels, heightPixels, framesPerSecond, bitrateKbps;
  final int frameQueueDepth, inputQueueDepth;

  Map<String, Object> toJson() => {
    'codec': _codec(codec),
    'codecId': _identity(codecId),
    'codecRevision': _checkedRevision(codecRevision),
    'displayId': _integer(displayId, 0, 63),
    'displayRevision': _checkedRevision(displayRevision),
    'networkId': _identity(networkId),
    'networkRevision': _checkedRevision(networkRevision),
    'policyId': _identity(policyId),
    'policyRevision': _checkedRevision(policyRevision),
    'widthPixels': _integer(widthPixels, 320, 8192),
    'heightPixels': _integer(heightPixels, 320, 8192),
    'framesPerSecond': _integer(framesPerSecond, 24, 240),
    'bitrateKbps': _integer(bitrateKbps, 2000, 100000),
    'frameQueueDepth': _integer(frameQueueDepth, 1, 3),
    'inputQueueDepth': _integer(inputQueueDepth, 1, 32),
    'secureSurface': true,
  };

  factory CoreGameStreamSelectedQuality.fromJson(Object? raw) {
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
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamSelectedQuality(
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
      framesPerSecond: _integer(value['framesPerSecond'], 24, 240),
      bitrateKbps: _integer(value['bitrateKbps'], 2000, 100000),
      frameQueueDepth: _integer(value['frameQueueDepth'], 1, 3),
      inputQueueDepth: _integer(value['inputQueueDepth'], 1, 32),
    );
  }
}

final class CoreGameStreamSession {
  CoreGameStreamSession._({
    required this.id,
    required this.hostId,
    required this.appId,
    required this.revision,
    required this.state,
    required this.expiresAt,
    required this.accountRevision,
    required this.hostRevision,
    required this.pairingRevision,
    required this.catalogRevision,
    required this.appRevision,
    required this.clientAuthority,
    required this.selectedQuality,
  });

  factory CoreGameStreamSession.fromJson(
    Object? raw, {
    String? expectedHostId,
    String? expectedAppId,
  }) {
    final value = _exactMap(raw, {
      'schemaVersion',
      'id',
      'hostId',
      'appId',
      'revision',
      'state',
      'expiresAt',
      'coreAuthority',
      'selectedQuality',
      'clientAuthority',
    });
    final hostId = _identity(value['hostId']);
    final appId = _identity(value['appId']);
    if (value['schemaVersion'] != 2 ||
        (expectedHostId != null && hostId != expectedHostId) ||
        (expectedAppId != null && appId != expectedAppId) ||
        !{'open', 'retired', 'unknown'}.contains(value['state'])) {
      throw const LarenorServerException('invalid_response');
    }
    final core = _exactMap(value['coreAuthority'], {
      'accountRevision',
      'hostRevision',
      'pairingRevision',
      'catalogRevision',
      'appRevision',
      'selectedQuality',
    });
    final client = _parseClientAuthority(value['clientAuthority']);
    final selected = CoreGameStreamSelectedQuality.fromJson(
      value['selectedQuality'],
    );
    final coreSelected = CoreGameStreamSelectedQuality.fromJson(
      core['selectedQuality'],
    );
    if (!_sameQuality(selected, coreSelected) ||
        selected.displayRevision != client.displayRevision ||
        selected.networkRevision != client.networkRevision ||
        selected.policyRevision != client.policyRevision) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamSession._(
      id: _identity(value['id']),
      hostId: hostId,
      appId: appId,
      revision: _revision(value['revision']),
      state: value['state']! as String,
      expiresAt: _epoch(value['expiresAt']),
      accountRevision: _revision(core['accountRevision']),
      hostRevision: _revision(core['hostRevision']),
      pairingRevision: _revision(core['pairingRevision']),
      catalogRevision: _revision(core['catalogRevision']),
      appRevision: _revision(core['appRevision']),
      clientAuthority: client,
      selectedQuality: selected,
    );
  }

  final String id, hostId, appId, state;
  final int revision;
  final DateTime expiresAt;
  final int accountRevision, hostRevision, pairingRevision;
  final int catalogRevision, appRevision;
  final CoreGameStreamClientAuthority clientAuthority;
  final CoreGameStreamSelectedQuality selectedQuality;
}

final class CoreGameStreamCommand {
  CoreGameStreamCommand._({
    required this.id,
    required this.sessionId,
    required this.intent,
    required this.state,
    required this.result,
    required this.observationKind,
    required this.readbackRevision,
  });

  factory CoreGameStreamCommand.fromJson(
    Object? raw, {
    required String sessionId,
    String? expectedIntent,
  }) {
    final value = _exactMap(raw, {
      'schemaVersion',
      'id',
      'sessionId',
      'intent',
      'state',
      'result',
      'observationKind',
      'readbackRevision',
      'createdAt',
      'completedAt',
    });
    final intent = value['intent'];
    final state = value['state'];
    final result = value['result'];
    final observation = value['observationKind'];
    final readback = value['readbackRevision'];
    if (value['schemaVersion'] != 2 ||
        value['sessionId'] != sessionId ||
        intent is! String ||
        !{'wake', 'launch', 'stream', 'stop'}.contains(intent) ||
        (expectedIntent != null && intent != expectedIntent) ||
        state is! String ||
        !{
          'authorized',
          'native_observed',
          'rejected',
          'unknown',
        }.contains(state) ||
        !_validCommandOutcome(intent, state, result, observation, readback) ||
        !_validLifecycleEpochs(
          value['createdAt'],
          value['completedAt'],
          terminal: state != 'authorized',
        )) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamCommand._(
      id: _identity(value['id']),
      sessionId: sessionId,
      intent: intent,
      state: state,
      result: result as String?,
      observationKind: observation as String?,
      readbackRevision: readback == null ? null : _revision(readback),
    );
  }

  final String id, sessionId, intent, state;
  final String? result, observationKind;
  final int? readbackRevision;
}

final class CoreGameStreamAuthorization {
  const CoreGameStreamAuthorization({
    required this.command,
    required this.dispatchGrant,
  });

  final CoreGameStreamCommand command;

  /// Null means Core has already handed this operation to a dispatcher. The
  /// Client may reconcile it, but must never invoke native execution again.
  final String? dispatchGrant;
}

final class CoreGameStreamRevocation {
  CoreGameStreamRevocation._({
    required this.id,
    required this.hostId,
    required this.hostRevision,
    required this.state,
    required this.readbackRevision,
    required this.nativeReceiptDigest,
  });

  factory CoreGameStreamRevocation.fromJson(
    Object? raw, {
    required String hostId,
  }) {
    final value = _exactMap(raw, {
      'schemaVersion',
      'id',
      'hostId',
      'hostRevision',
      'state',
      'readbackRevision',
      'nativeReceiptDigest',
      'createdAt',
      'completedAt',
    });
    if (value['schemaVersion'] != 2 ||
        value['hostId'] != hostId ||
        !{
          'core_retired',
          'local_cleared',
          'unknown',
        }.contains(value['state']) ||
        !_validRevocationEvidence(
          value['state'],
          value['readbackRevision'],
          value['nativeReceiptDigest'],
        ) ||
        !_validLifecycleEpochs(
          value['createdAt'],
          value['completedAt'],
          terminal: value['state'] != 'core_retired',
        )) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamRevocation._(
      id: _identity(value['id']),
      hostId: hostId,
      hostRevision: _revision(value['hostRevision']),
      state: value['state']! as String,
      readbackRevision: value['readbackRevision'] == null
          ? null
          : _revision(value['readbackRevision']),
      nativeReceiptDigest: value['nativeReceiptDigest'] == null
          ? null
          : value['nativeReceiptDigest']! as String,
    );
  }

  factory CoreGameStreamRevocation.recovery({
    required String id,
    required String hostId,
    required int hostRevision,
  }) => CoreGameStreamRevocation._(
    id: _identity(id),
    hostId: _identity(hostId),
    hostRevision: _revision(hostRevision),
    state: 'core_retired',
    readbackRevision: null,
    nativeReceiptDigest: null,
  );

  final String id, hostId, state;
  final int hostRevision;
  final int? readbackRevision;
  final String? nativeReceiptDigest;
}

final class CoreGameStreamApi {
  CoreGameStreamApi(
    this._api,
    this._session, {
    required bool Function() isCurrent,
  }) : _current = isCurrent;

  final LarenorServerApi _api;
  final ServerSession _session;
  final bool Function() _current;
  bool _retired = false;

  ServerContext get _context => _session.context!;
  String get _root => '/game-streaming/${_context.coreId}/${_context.homeId}';

  void retire() => _retired = true;

  void _check() {
    try {
      if (!_retired && _current()) return;
    } catch (_) {}
    _retired = true;
    throw const LarenorServerException('cancelled');
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
    _check();
    try {
      final value = await action();
      _check();
      return value;
    } catch (_) {
      _check();
      rethrow;
    }
  }

  Future<CoreGameStreamPairingIntent> createPairing({
    required String requestKey,
    required int accountRevision,
    required DateTime expiresAt,
  }) => _operation(() async {
    final response = await _api.request(
      'POST',
      '$_root/pairings',
      token: _session.accessToken,
      body: {
        'schemaVersion': 2,
        'requestKey': _requestKey(requestKey),
        'accountRevision': _checkedRevision(accountRevision),
        'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch / 1000,
      },
    );
    return CoreGameStreamPairingIntent.fromJson(response);
  });

  Future<CoreGameStreamRegistration> completePairing(
    CoreGameStreamPairingIntent intent,
    CoreNativePairingObservation observation,
  ) => _operation(() async {
    final grant = intent.pairingGrant;
    if (grant == null) {
      throw const LarenorServerException(
        'game_stream_pairing_reconcile_required',
      );
    }
    final value = _exactMap(
      await _api.request(
        'POST',
        '$_root/pairings/${intent.id}/complete',
        token: _session.accessToken,
        body: {
          'schemaVersion': 2,
          'expectedPairingRevision': intent.revision,
          'pairingGrant': grant,
          'observation': observation.toJson(),
        },
      ),
      {'schemaVersion', 'host', 'apps', 'registrationMapping'},
    );
    if (value['schemaVersion'] != 2) {
      throw const LarenorServerException('invalid_response');
    }
    final host = CoreGameStreamHost.fromJson(value['host']);
    final rawApps = value['apps'];
    if (rawApps is! List || rawApps.length > 256) {
      throw const LarenorServerException('invalid_response');
    }
    final apps = rawApps
        .map((item) => CoreGameStreamApp.fromJson(item, hostId: host.id))
        .toList(growable: false);
    if (apps.map((item) => item.id).toSet().length != apps.length) {
      throw const LarenorServerException('invalid_response');
    }
    final mapping = _exactMap(value['registrationMapping'], {
      'nativeReceiptId',
      'hostId',
      'apps',
    });
    if (mapping['nativeReceiptId'] != observation.receiptId ||
        mapping['hostId'] != host.id ||
        mapping['apps'] is! List ||
        (mapping['apps'] as List).length != apps.length) {
      throw const LarenorServerException('invalid_response');
    }
    final byId = {for (final app in apps) app.id: app};
    final result = <CoreGameStreamRegistrationApp>[];
    for (final raw in mapping['apps']! as List) {
      final entry = _exactMap(raw, {'entryIndex', 'appId'});
      final index = _integer(entry['entryIndex'], 0, apps.length - 1);
      final app = byId[_identity(entry['appId'])];
      if (app == null || result.any((item) => item.entryIndex == index)) {
        throw const LarenorServerException('invalid_response');
      }
      result.add(CoreGameStreamRegistrationApp(entryIndex: index, app: app));
    }
    if (result.map((item) => item.app.id).toSet().length != apps.length) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamRegistration(
      host: host,
      apps: List.unmodifiable(apps),
      nativeReceiptId: observation.receiptId,
      mapping: List.unmodifiable(result),
    );
  });

  Future<CoreGameStreamCatalogIntent> createCatalogObservation(
    CoreGameStreamHost host, {
    required String requestKey,
    required int accountRevision,
    required DateTime expiresAt,
  }) => _operation(
    () async => CoreGameStreamCatalogIntent.fromJson(
      await _api.request(
        'POST',
        '$_root/hosts/${host.id}/catalog-observations',
        token: _session.accessToken,
        body: {
          'schemaVersion': 2,
          'requestKey': _requestKey(requestKey),
          'expectedHostRevision': host.revision,
          'expectedPairingRevision': host.pairingRevision,
          'expectedCatalogRevision': host.catalogRevision,
          'accountRevision': _checkedRevision(accountRevision),
          'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch / 1000,
        },
      ),
      hostId: host.id,
    ),
  );

  Future<CoreGameStreamCatalogUpdate> completeCatalogObservation(
    CoreGameStreamHost host,
    CoreGameStreamCatalogIntent intent,
    CoreNativeCatalogObservation observation,
  ) => _operation(() async {
    final grant = intent.catalogGrant;
    if (grant == null || intent.hostId != host.id) {
      throw const LarenorServerException(
        'game_stream_catalog_reconcile_required',
      );
    }
    final value = _exactMap(
      await _api.request(
        'POST',
        '$_root/hosts/${host.id}/catalog-observations/${intent.id}/complete',
        token: _session.accessToken,
        body: {
          'schemaVersion': 2,
          'expectedObservationRevision': intent.revision,
          'catalogGrant': grant,
          'observation': observation.toJson(),
        },
      ),
      {
        'schemaVersion',
        'hostRevision',
        'pairingRevision',
        'catalogRevision',
        'apps',
        'registrationMapping',
      },
    );
    final hostRevision = _revision(value['hostRevision']);
    final pairingRevision = _revision(value['pairingRevision']);
    final catalogRevision = _revision(value['catalogRevision']);
    final rawApps = value['apps'];
    if (value['schemaVersion'] != 2 ||
        rawApps is! List ||
        rawApps.length > 256 ||
        catalogRevision <= host.catalogRevision) {
      throw const LarenorServerException('invalid_response');
    }
    final apps = rawApps
        .map((item) => CoreGameStreamApp.fromJson(item, hostId: host.id))
        .toList(growable: false);
    if (apps.map((item) => item.id).toSet().length != apps.length) {
      throw const LarenorServerException('invalid_response');
    }
    final mapping = _exactMap(value['registrationMapping'], {
      'nativeReceiptId',
      'hostId',
      'apps',
    });
    final rawMapping = mapping['apps'];
    if (mapping['nativeReceiptId'] != observation.receiptId ||
        mapping['hostId'] != host.id ||
        rawMapping is! List ||
        rawMapping.length != apps.length) {
      throw const LarenorServerException('invalid_response');
    }
    final byId = {for (final app in apps) app.id: app};
    final entries = <CoreGameStreamRegistrationApp>[];
    for (final raw in rawMapping) {
      final entry = _exactMap(raw, {'entryIndex', 'appId'});
      final index = _integer(
        entry['entryIndex'],
        0,
        observation.apps.length - 1,
      );
      final app = byId[_identity(entry['appId'])];
      if (app == null || entries.any((item) => item.entryIndex == index)) {
        throw const LarenorServerException('invalid_response');
      }
      entries.add(CoreGameStreamRegistrationApp(entryIndex: index, app: app));
    }
    if (entries.map((item) => item.app.id).toSet().length != apps.length) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamCatalogUpdate(
      hostId: host.id,
      hostRevision: hostRevision,
      pairingRevision: pairingRevision,
      catalogRevision: catalogRevision,
      apps: List.unmodifiable(apps),
      nativeReceiptId: observation.receiptId,
      mapping: List.unmodifiable(entries),
    );
  });

  Future<CoreGameStreamHosts> hosts() => _operation(() async {
    final response = _exactMap(
      await _api.request('GET', '$_root/hosts', token: _session.accessToken),
      {'schemaVersion', 'scope', 'accountRevision', 'hosts'},
    );
    final scope = _exactMap(response['scope'], {
      'schemaVersion',
      'coreId',
      'homeId',
    });
    final rawHosts = response['hosts'];
    if (response['schemaVersion'] != 2 ||
        scope['schemaVersion'] != 1 ||
        scope['coreId'] != _context.coreId ||
        scope['homeId'] != _context.homeId ||
        rawHosts is! List ||
        rawHosts.length > 64) {
      throw const LarenorServerException('invalid_response');
    }
    final hosts = rawHosts
        .map(CoreGameStreamHost.fromJson)
        .toList(growable: false);
    if (hosts.map((item) => item.id).toSet().length != hosts.length) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamHosts(
      accountRevision: _revision(response['accountRevision']),
      hosts: List.unmodifiable(hosts),
    );
  });

  Future<CoreGameStreamCatalog> apps(CoreGameStreamHost host) =>
      _operation(() async {
        final response = _exactMap(
          await _api.request(
            'GET',
            '$_root/hosts/${host.id}/apps',
            token: _session.accessToken,
          ),
          {
            'schemaVersion',
            'hostRevision',
            'pairingRevision',
            'catalogRevision',
            'apps',
          },
        );
        final rawApps = response['apps'];
        if (response['schemaVersion'] != 2 ||
            response['hostRevision'] != host.revision ||
            response['pairingRevision'] != host.pairingRevision ||
            response['catalogRevision'] != host.catalogRevision ||
            rawApps is! List ||
            rawApps.length > 256) {
          throw const LarenorServerException('invalid_response');
        }
        final apps = rawApps
            .map((item) => CoreGameStreamApp.fromJson(item, hostId: host.id))
            .toList(growable: false);
        if (apps.map((item) => item.id).toSet().length != apps.length) {
          throw const LarenorServerException('invalid_response');
        }
        return CoreGameStreamCatalog(host: host, apps: List.unmodifiable(apps));
      });

  Future<CoreGameStreamSession> open({
    required CoreGameStreamHost host,
    required CoreGameStreamApp app,
    required int accountRevision,
    required CoreGameStreamClientAuthority clientAuthority,
    required CoreGameStreamSelectedQuality selectedQuality,
    required String requestKey,
    required DateTime expiresAt,
  }) => _operation(() async {
    if (app.hostId != host.id) {
      throw const LarenorServerException('invalid_request');
    }
    return CoreGameStreamSession.fromJson(
      await _api.request(
        'POST',
        '$_root/hosts/${host.id}/apps/${app.id}/sessions',
        token: _session.accessToken,
        body: {
          'schemaVersion': 2,
          'requestKey': _requestKey(requestKey),
          'expectedHostRevision': host.revision,
          'expectedPairingRevision': host.pairingRevision,
          'expectedCatalogRevision': host.catalogRevision,
          'expectedAppRevision': app.revision,
          'accountRevision': _checkedRevision(accountRevision),
          'clientAuthority': clientAuthority.toJson(),
          'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch / 1000,
          'selectedQuality': selectedQuality.toJson(),
        },
      ),
      expectedHostId: host.id,
      expectedAppId: app.id,
    );
  });

  Future<CoreGameStreamSession> readSession(String sessionId) => _operation(
    () async => CoreGameStreamSession.fromJson(
      await _api.request(
        'GET',
        '$_root/sessions/${_identity(sessionId)}',
        token: _session.accessToken,
      ),
    ),
  );

  Future<CoreGameStreamSession> retireSession(
    CoreGameStreamSession session, {
    required String requestKey,
  }) => _operation(
    () async => CoreGameStreamSession.fromJson(
      await _api.request(
        'POST',
        '$_root/sessions/${session.id}/retire',
        token: _session.accessToken,
        body: {
          'schemaVersion': 2,
          'requestKey': _requestKey(requestKey),
          'expectedSessionRevision': session.revision,
        },
      ),
      expectedHostId: session.hostId,
      expectedAppId: session.appId,
    ),
  );

  Future<CoreGameStreamAuthorization> authorize(
    CoreGameStreamSession session, {
    required String requestKey,
    required String intent,
  }) => _operation(() async {
    _intent(intent);
    final response = _exactMap(
      await _api.request(
        'POST',
        '$_root/sessions/${session.id}/commands',
        token: _session.accessToken,
        body: {
          'schemaVersion': 2,
          'requestKey': _requestKey(requestKey),
          'expectedSessionRevision': session.revision,
          'intent': intent,
        },
      ),
      {'schemaVersion', 'command', 'dispatchGrant'},
    );
    final grant = response['dispatchGrant'];
    final command = CoreGameStreamCommand.fromJson(
      response['command'],
      sessionId: session.id,
      expectedIntent: intent,
    );
    if (response['schemaVersion'] != 2 ||
        (grant != null && !_isIdentity(grant)) ||
        (grant != null && command.state != 'authorized') ||
        (grant == null && command.state == 'authorized')) {
      throw const LarenorServerException('invalid_response');
    }
    return CoreGameStreamAuthorization(
      command: command,
      dispatchGrant: grant as String?,
    );
  });

  Future<CoreGameStreamCommand> readCommand(
    CoreGameStreamSession session,
    String commandId,
  ) => _operation(
    () async => CoreGameStreamCommand.fromJson(
      await _api.request(
        'GET',
        '$_root/sessions/${session.id}/commands/${_identity(commandId)}',
        token: _session.accessToken,
      ),
      sessionId: session.id,
    ),
  );

  Future<CoreGameStreamCommand> complete(
    CoreGameStreamSession session,
    CoreGameStreamAuthorization authorization, {
    required String state,
    required String result,
    required String observationKind,
    int? readbackRevision,
    String? nativeReceiptDigest,
  }) => _operation(() async {
    final grant = authorization.dispatchGrant;
    if (grant == null) {
      throw const LarenorServerException('game_stream_reconcile_required');
    }
    return CoreGameStreamCommand.fromJson(
      await _api.request(
        'POST',
        '$_root/sessions/${session.id}/commands/${authorization.command.id}/complete',
        token: _session.accessToken,
        body: {
          'schemaVersion': 2,
          'expectedSessionRevision': session.revision,
          'dispatchGrant': grant,
          'state': state,
          'result': result,
          'observationKind': observationKind,
          'readbackRevision': readbackRevision,
          'nativeReceiptDigest': nativeReceiptDigest,
        },
      ),
      sessionId: session.id,
      expectedIntent: authorization.command.intent,
    );
  });

  Future<CoreGameStreamRevocation> revoke(
    CoreGameStreamHost host, {
    required String requestKey,
  }) => _operation(
    () async => CoreGameStreamRevocation.fromJson(
      await _api.request(
        'POST',
        '$_root/hosts/${host.id}/revoke',
        token: _session.accessToken,
        body: {
          'schemaVersion': 2,
          'requestKey': _requestKey(requestKey),
          'expectedHostRevision': host.revision,
          'expectedPairingRevision': host.pairingRevision,
          'expectedCatalogRevision': host.catalogRevision,
        },
      ),
      hostId: host.id,
    ),
  );

  Future<CoreGameStreamRevocation> completeRevocation(
    CoreGameStreamRevocation revocation, {
    required String state,
    required int? readbackRevision,
    required String? nativeReceiptDigest,
  }) => _operation(() async {
    if (!{'local_cleared', 'unknown'}.contains(state) ||
        !_validRevocationEvidence(
          state,
          readbackRevision,
          nativeReceiptDigest,
        )) {
      throw const LarenorServerException('invalid_request');
    }
    return CoreGameStreamRevocation.fromJson(
      await _api.request(
        'POST',
        '$_root/hosts/${revocation.hostId}/revocations/${revocation.id}/complete',
        token: _session.accessToken,
        body: {
          'schemaVersion': 2,
          'state': state,
          'readbackRevision': readbackRevision,
          'nativeReceiptDigest': nativeReceiptDigest,
        },
      ),
      hostId: revocation.hostId,
    );
  });
}

bool _validRevocationEvidence(
  Object? state,
  Object? readbackRevision,
  Object? nativeReceiptDigest,
) {
  if (state == 'core_retired') {
    return readbackRevision == null && nativeReceiptDigest == null;
  }
  if (state == 'unknown') {
    return readbackRevision == null && nativeReceiptDigest == null;
  }
  return state == 'local_cleared' &&
      _validRevision(readbackRevision) &&
      nativeReceiptDigest is String &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(nativeReceiptDigest);
}

bool _sameQuality(
  CoreGameStreamSelectedQuality left,
  CoreGameStreamSelectedQuality right,
) => left.toJson().toString() == right.toJson().toString();

CoreGameStreamClientAuthority _parseClientAuthority(Object? raw) {
  final value = _exactMap(raw, {
    'routeRevision',
    'lifecycleRevision',
    'displayRevision',
    'networkRevision',
    'policyRevision',
  });
  return CoreGameStreamClientAuthority(
    routeRevision: _revision(value['routeRevision']),
    lifecycleRevision: _revision(value['lifecycleRevision']),
    displayRevision: _revision(value['displayRevision']),
    networkRevision: _revision(value['networkRevision']),
    policyRevision: _revision(value['policyRevision']),
  );
}

bool _validCommandOutcome(
  String intent,
  String state,
  Object? result,
  Object? observation,
  Object? readback,
) {
  if (state == 'authorized') {
    return result == null && observation == null && readback == null;
  }
  if (state == 'unknown') {
    return result == 'unknown' && observation == 'unknown' && readback == null;
  }
  if (state == 'rejected') {
    return result == 'rejected' &&
        observation == 'nativeRejected' &&
        _validRevision(readback);
  }
  final expected = switch (intent) {
    'wake' => {('hostAwake', 'serverInfoOnline')},
    'launch' => {('appRunning', 'currentGameMatched')},
    'stream' => {('streaming', 'connectionStarted')},
    'stop' => {
      ('stopped', 'connectionStopped'),
      ('stopped', 'connectionTerminated'),
    },
    _ => <(String, String)>{},
  };
  return state == 'native_observed' &&
      expected.contains((result, observation)) &&
      readback != null &&
      _validRevision(readback);
}

Map<String, dynamic> _exactMap(Object? raw, Set<String> keys) {
  if (raw is! Map<String, dynamic> ||
      raw.length != keys.length ||
      !raw.keys.every(keys.contains)) {
    throw const LarenorServerException('invalid_response');
  }
  return raw;
}

bool _isIdentity(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

String _identity(Object? value) => _isIdentity(value)
    ? value! as String
    : throw const LarenorServerException('invalid_response');

bool _validRevision(Object? value) =>
    value is int && value >= 1 && value <= gameStreamMaxSafeInteger;

int _revision(Object? value) => _validRevision(value)
    ? value! as int
    : throw const LarenorServerException('invalid_response');

int _checkedRevision(int value) => _revision(value);

int _integer(Object? value, int min, int max) =>
    value is int && value >= min && value <= max
    ? value
    : throw const LarenorServerException('invalid_response');

String _text(Object? value, int max) =>
    value is String &&
        value.trim() == value &&
        value.isNotEmpty &&
        value.length <= max &&
        !value.contains(RegExp(r'[\x00-\x1f\x7f]'))
    ? value
    : throw const LarenorServerException('invalid_response');

DateTime _epoch(Object? value) {
  if (value is! num || !value.isFinite || value <= 0) {
    throw const LarenorServerException('invalid_response');
  }
  return DateTime.fromMillisecondsSinceEpoch(
    (value * 1000).round(),
    isUtc: true,
  );
}

bool _validLifecycleEpochs(
  Object? createdAt,
  Object? completedAt, {
  required bool terminal,
}) {
  try {
    _epoch(createdAt);
    if (terminal) {
      _epoch(completedAt);
    } else if (completedAt != null) {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

String _requestKey(String value) =>
    value.length >= 16 &&
        value.length <= 128 &&
        RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)
    ? value
    : throw const LarenorServerException('invalid_request');

String _intent(String value) =>
    {'wake', 'launch', 'stream', 'stop'}.contains(value)
    ? value
    : throw const LarenorServerException('invalid_request');

String _codec(Object? value) =>
    value is String && {'h264', 'hevc', 'av1'}.contains(value)
    ? value
    : throw const LarenorServerException('invalid_response');
