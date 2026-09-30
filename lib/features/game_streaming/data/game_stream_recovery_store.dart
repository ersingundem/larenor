import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/game_stream_session.dart';
import 'android_game_stream_v2_port.dart';
import 'core_game_stream_api.dart';

abstract interface class GameStreamRecoveryBackend {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

final class SecureGameStreamRecoveryBackend
    implements GameStreamRecoveryBackend {
  SecureGameStreamRecoveryBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'larenor.game_stream.v2.pending';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: key);

  @override
  Future<void> write(String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete() => _storage.delete(key: key);
}

final class GameStreamRecoveryScope {
  GameStreamRecoveryScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.familyId,
  }) {
    for (final value in [coreId, homeId, accountId, familyId]) {
      _identity(value);
    }
  }

  final String coreId, homeId, accountId, familyId;

  Map<String, Object> toJson() => {
    'coreId': coreId,
    'homeId': homeId,
    'accountId': accountId,
    'familyId': familyId,
  };

  bool same(GameStreamRecoveryScope other) =>
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      familyId == other.familyId;
}

sealed class GameStreamPendingOperation {
  const GameStreamPendingOperation();

  GameStreamRecoveryScope get scope;
  Map<String, Object> toJson();
  bool sameOperation(GameStreamPendingOperation other);
}

final class GameStreamRecoveryRecord extends GameStreamPendingOperation {
  GameStreamRecoveryRecord({
    required this.scope,
    required this.sessionId,
    required this.sessionRevision,
    required this.commandId,
    required this.intent,
    required this.dispatchGrant,
    this.nativeRetired = false,
  }) {
    _identity(sessionId);
    _revision(sessionRevision);
    _identity(commandId);
    _identity(dispatchGrant);
    if (!{'wake', 'launch', 'stream', 'stop'}.contains(intent)) {
      throw ArgumentError('invalid_intent');
    }
  }

  @override
  final GameStreamRecoveryScope scope;
  final String sessionId, commandId, intent, dispatchGrant;
  final int sessionRevision;
  final bool nativeRetired;

  @override
  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'scope': scope.toJson(),
    'sessionId': sessionId,
    'sessionRevision': sessionRevision,
    'commandId': commandId,
    'intent': intent,
    'dispatchGrant': dispatchGrant,
    'nativeRetired': nativeRetired,
  };

  @override
  bool sameOperation(GameStreamPendingOperation other) =>
      other is GameStreamRecoveryRecord &&
      scope.same(other.scope) &&
      sessionId == other.sessionId &&
      sessionRevision == other.sessionRevision &&
      commandId == other.commandId &&
      intent == other.intent &&
      dispatchGrant == other.dispatchGrant &&
      nativeRetired == other.nativeRetired;

  GameStreamRecoveryRecord withNativeRetired() => GameStreamRecoveryRecord(
    scope: scope,
    sessionId: sessionId,
    sessionRevision: sessionRevision,
    commandId: commandId,
    intent: intent,
    dispatchGrant: dispatchGrant,
    nativeRetired: true,
  );

  factory GameStreamRecoveryRecord.fromJson(Object? raw) {
    final keys = {
      'schemaVersion',
      'scope',
      'sessionId',
      'sessionRevision',
      'commandId',
      'intent',
      'dispatchGrant',
    };
    if (raw is Map && raw.containsKey('nativeRetired')) {
      keys.add('nativeRetired');
    }
    final value = _map(raw, keys);
    final scope = _map(value['scope'], {
      'coreId',
      'homeId',
      'accountId',
      'familyId',
    });
    if (value['schemaVersion'] != 1) {
      throw const GameStreamException('invalid_recovery_record');
    }
    return GameStreamRecoveryRecord(
      scope: GameStreamRecoveryScope(
        coreId: _identity(scope['coreId']),
        homeId: _identity(scope['homeId']),
        accountId: _identity(scope['accountId']),
        familyId: _identity(scope['familyId']),
      ),
      sessionId: _identity(value['sessionId']),
      sessionRevision: _revision(value['sessionRevision']),
      commandId: _identity(value['commandId']),
      intent: value['intent'] is String
          ? value['intent']! as String
          : throw const GameStreamException('invalid_recovery_record'),
      dispatchGrant: _identity(value['dispatchGrant']),
      nativeRetired: value.containsKey('nativeRetired')
          ? _boolean(value['nativeRetired'])
          : false,
    );
  }

  @override
  String toString() => 'GameStreamRecoveryRecord(<redacted>)';
}

final class GameStreamPairingRecovery extends GameStreamPendingOperation {
  GameStreamPairingRecovery({
    required this.scope,
    required this.authority,
    required this.accountRevision,
    required this.pairingId,
    required this.pairingRevision,
    required this.pairingGrant,
    required this.expiresAtMillis,
    this.pairingDispatched = false,
    this.authorityRetirementPending = false,
    this.authorityRetired = false,
  }) {
    if (!_authorityScopeMatches(scope, authority) ||
        accountRevision != authority.accountRevision) {
      throw const GameStreamException('invalid_recovery_record');
    }
    _revision(accountRevision);
    _identity(pairingId);
    _revision(pairingRevision);
    _identity(pairingGrant);
    _timestamp(expiresAtMillis);
  }

  @override
  final GameStreamRecoveryScope scope;
  final AndroidGameStreamAuthorityV2 authority;
  final int accountRevision, pairingRevision, expiresAtMillis;
  final String pairingId, pairingGrant;
  final bool pairingDispatched;
  final bool authorityRetirementPending, authorityRetired;

  @override
  Map<String, Object> toJson() => _effectJson('pair', scope, {
    'authority': authority.toJson(),
    'accountRevision': accountRevision,
    'pairingId': pairingId,
    'pairingRevision': pairingRevision,
    'pairingGrant': pairingGrant,
    'expiresAtMillis': expiresAtMillis,
    'pairingDispatched': pairingDispatched,
    'authorityRetirementPending': authorityRetirementPending,
    'authorityRetired': authorityRetired,
  });

  @override
  bool sameOperation(GameStreamPendingOperation other) =>
      other is GameStreamPairingRecovery &&
      scope.same(other.scope) &&
      _sameAuthority(authority, other.authority) &&
      accountRevision == other.accountRevision &&
      pairingId == other.pairingId &&
      pairingRevision == other.pairingRevision &&
      pairingGrant == other.pairingGrant &&
      expiresAtMillis == other.expiresAtMillis &&
      pairingDispatched == other.pairingDispatched &&
      authorityRetirementPending == other.authorityRetirementPending &&
      authorityRetired == other.authorityRetired;

  GameStreamPairingRecovery withPairingDispatched() =>
      GameStreamPairingRecovery(
        scope: scope,
        authority: authority,
        accountRevision: accountRevision,
        pairingId: pairingId,
        pairingRevision: pairingRevision,
        pairingGrant: pairingGrant,
        expiresAtMillis: expiresAtMillis,
        pairingDispatched: true,
        authorityRetirementPending: authorityRetirementPending,
        authorityRetired: authorityRetired,
      );

  GameStreamPairingRecovery withAuthorityRetirementPending() =>
      GameStreamPairingRecovery(
        scope: scope,
        authority: authority,
        accountRevision: accountRevision,
        pairingId: pairingId,
        pairingRevision: pairingRevision,
        pairingGrant: pairingGrant,
        expiresAtMillis: expiresAtMillis,
        pairingDispatched: pairingDispatched,
        authorityRetirementPending: true,
        authorityRetired: authorityRetired,
      );

  GameStreamPairingRecovery withAuthorityRetired() => GameStreamPairingRecovery(
    scope: scope,
    authority: authority,
    accountRevision: accountRevision,
    pairingId: pairingId,
    pairingRevision: pairingRevision,
    pairingGrant: pairingGrant,
    expiresAtMillis: expiresAtMillis,
    pairingDispatched: pairingDispatched,
    authorityRetirementPending: true,
    authorityRetired: true,
  );
}

final class GameStreamCatalogRecovery extends GameStreamPendingOperation {
  GameStreamCatalogRecovery({
    required this.scope,
    required this.authority,
    required this.accountRevision,
    required this.observationId,
    required this.observationRevision,
    required this.catalogGrant,
    required this.expiresAtMillis,
    required this.host,
    this.nativeBindingId,
    this.bindingRevision,
    this.registrationRevision,
    this.engineRevision,
    this.catalogDispatched = false,
    this.authorityRetirementPending = false,
    this.authorityRetired = false,
  }) {
    final hasAnyBinding =
        nativeBindingId != null ||
        bindingRevision != null ||
        registrationRevision != null ||
        engineRevision != null;
    final hasCompleteBinding =
        nativeBindingId != null &&
        bindingRevision != null &&
        registrationRevision != null &&
        engineRevision != null;
    if (!_authorityScopeMatches(scope, authority) ||
        accountRevision != authority.accountRevision ||
        (hasAnyBinding && !hasCompleteBinding)) {
      throw const GameStreamException('invalid_recovery_record');
    }
    _revision(accountRevision);
    _identity(observationId);
    _revision(observationRevision);
    _identity(catalogGrant);
    _timestamp(expiresAtMillis);
    if (nativeBindingId != null) {
      _identity(nativeBindingId);
      _revision(bindingRevision);
      _revision(registrationRevision);
      _engine(engineRevision);
    }
  }

  @override
  final GameStreamRecoveryScope scope;
  final AndroidGameStreamAuthorityV2 authority;
  final int accountRevision, observationRevision, expiresAtMillis;
  final String observationId, catalogGrant;
  final CoreGameStreamHost host;
  final String? nativeBindingId, engineRevision;
  final int? bindingRevision, registrationRevision;
  final bool catalogDispatched;
  final bool authorityRetirementPending, authorityRetired;

  bool get hasBinding => nativeBindingId != null;

  @override
  Map<String, Object> toJson() {
    final payload = <String, Object>{
      'authority': authority.toJson(),
      'accountRevision': accountRevision,
      'observationId': observationId,
      'observationRevision': observationRevision,
      'catalogGrant': catalogGrant,
      'expiresAtMillis': expiresAtMillis,
      'host': {
        'id': host.id,
        'revision': host.revision,
        'pairingRevision': host.pairingRevision,
        'catalogRevision': host.catalogRevision,
        'name': host.name,
        'codecs': host.codecs,
      },
      'authorityRetirementPending': authorityRetirementPending,
      'catalogDispatched': catalogDispatched,
      'authorityRetired': authorityRetired,
    };
    if (nativeBindingId != null) {
      payload.addAll({
        'nativeBindingId': nativeBindingId!,
        'bindingRevision': bindingRevision!,
        'registrationRevision': registrationRevision!,
        'engineRevision': engineRevision!,
      });
    }
    return _effectJson('catalog', scope, payload);
  }

  @override
  bool sameOperation(GameStreamPendingOperation other) =>
      other is GameStreamCatalogRecovery &&
      scope.same(other.scope) &&
      _sameAuthority(authority, other.authority) &&
      accountRevision == other.accountRevision &&
      observationId == other.observationId &&
      observationRevision == other.observationRevision &&
      catalogGrant == other.catalogGrant &&
      expiresAtMillis == other.expiresAtMillis &&
      _sameHost(host, other.host) &&
      nativeBindingId == other.nativeBindingId &&
      bindingRevision == other.bindingRevision &&
      registrationRevision == other.registrationRevision &&
      engineRevision == other.engineRevision &&
      catalogDispatched == other.catalogDispatched &&
      authorityRetirementPending == other.authorityRetirementPending &&
      authorityRetired == other.authorityRetired;

  GameStreamCatalogRecovery withBinding({
    required String nativeBindingId,
    required int bindingRevision,
    required int registrationRevision,
    required String engineRevision,
  }) => GameStreamCatalogRecovery(
    scope: scope,
    authority: authority,
    accountRevision: accountRevision,
    observationId: observationId,
    observationRevision: observationRevision,
    catalogGrant: catalogGrant,
    expiresAtMillis: expiresAtMillis,
    host: host,
    nativeBindingId: nativeBindingId,
    bindingRevision: bindingRevision,
    registrationRevision: registrationRevision,
    engineRevision: engineRevision,
    catalogDispatched: catalogDispatched,
    authorityRetirementPending: authorityRetirementPending,
    authorityRetired: authorityRetired,
  );

  GameStreamCatalogRecovery withCatalogDispatched() =>
      GameStreamCatalogRecovery(
        scope: scope,
        authority: authority,
        accountRevision: accountRevision,
        observationId: observationId,
        observationRevision: observationRevision,
        catalogGrant: catalogGrant,
        expiresAtMillis: expiresAtMillis,
        host: host,
        nativeBindingId: nativeBindingId,
        bindingRevision: bindingRevision,
        registrationRevision: registrationRevision,
        engineRevision: engineRevision,
        catalogDispatched: true,
        authorityRetirementPending: authorityRetirementPending,
        authorityRetired: authorityRetired,
      );

  GameStreamCatalogRecovery withAuthorityRetirementPending() =>
      GameStreamCatalogRecovery(
        scope: scope,
        authority: authority,
        accountRevision: accountRevision,
        observationId: observationId,
        observationRevision: observationRevision,
        catalogGrant: catalogGrant,
        expiresAtMillis: expiresAtMillis,
        host: host,
        nativeBindingId: nativeBindingId,
        bindingRevision: bindingRevision,
        registrationRevision: registrationRevision,
        engineRevision: engineRevision,
        catalogDispatched: catalogDispatched,
        authorityRetirementPending: true,
        authorityRetired: authorityRetired,
      );

  GameStreamCatalogRecovery withAuthorityRetired() => GameStreamCatalogRecovery(
    scope: scope,
    authority: authority,
    accountRevision: accountRevision,
    observationId: observationId,
    observationRevision: observationRevision,
    catalogGrant: catalogGrant,
    expiresAtMillis: expiresAtMillis,
    host: host,
    nativeBindingId: nativeBindingId,
    bindingRevision: bindingRevision,
    registrationRevision: registrationRevision,
    engineRevision: engineRevision,
    catalogDispatched: catalogDispatched,
    authorityRetirementPending: true,
    authorityRetired: true,
  );
}

/// A Core session exists, but native ownership has not yet been proven bound.
/// Recovery may only retire this exact session; it must never bind or execute.
final class GameStreamSessionBindRecovery extends GameStreamPendingOperation {
  GameStreamSessionBindRecovery({
    required this.scope,
    required this.accountRevision,
    required this.sessionId,
    required this.sessionRevision,
    required this.retireRequestKey,
    this.nativeRetired = false,
  }) {
    _revision(accountRevision);
    _identity(sessionId);
    _revision(sessionRevision);
    _requestKey(retireRequestKey);
  }

  @override
  final GameStreamRecoveryScope scope;
  final int accountRevision, sessionRevision;
  final String sessionId, retireRequestKey;
  final bool nativeRetired;

  @override
  Map<String, Object> toJson() => _effectJson('session_bind', scope, {
    'accountRevision': accountRevision,
    'sessionId': sessionId,
    'sessionRevision': sessionRevision,
    'retireRequestKey': retireRequestKey,
    'nativeRetired': nativeRetired,
  });

  @override
  bool sameOperation(GameStreamPendingOperation other) =>
      other is GameStreamSessionBindRecovery &&
      scope.same(other.scope) &&
      accountRevision == other.accountRevision &&
      sessionId == other.sessionId &&
      sessionRevision == other.sessionRevision &&
      retireRequestKey == other.retireRequestKey &&
      nativeRetired == other.nativeRetired;

  GameStreamSessionBindRecovery withNativeRetired() =>
      GameStreamSessionBindRecovery(
        scope: scope,
        accountRevision: accountRevision,
        sessionId: sessionId,
        sessionRevision: sessionRevision,
        retireRequestKey: retireRequestKey,
        nativeRetired: true,
      );
}

/// A causal stop command is terminal, but its exact native/Core session still
/// needs local retirement. Recovery never sends the stop command again.
final class GameStreamStopCleanupRecovery extends GameStreamPendingOperation {
  GameStreamStopCleanupRecovery({
    required this.scope,
    required this.accountRevision,
    required this.sessionId,
    required this.sessionRevision,
    required this.commandId,
    required this.retireRequestKey,
    this.nativeRetired = false,
  }) {
    _revision(accountRevision);
    _identity(sessionId);
    _revision(sessionRevision);
    _identity(commandId);
    _requestKey(retireRequestKey);
  }

  @override
  final GameStreamRecoveryScope scope;
  final int accountRevision, sessionRevision;
  final String sessionId, commandId, retireRequestKey;
  final bool nativeRetired;

  @override
  Map<String, Object> toJson() => _effectJson('stop_cleanup', scope, {
    'accountRevision': accountRevision,
    'sessionId': sessionId,
    'sessionRevision': sessionRevision,
    'commandId': commandId,
    'retireRequestKey': retireRequestKey,
    'nativeRetired': nativeRetired,
  });

  @override
  bool sameOperation(GameStreamPendingOperation other) =>
      other is GameStreamStopCleanupRecovery &&
      scope.same(other.scope) &&
      accountRevision == other.accountRevision &&
      sessionId == other.sessionId &&
      sessionRevision == other.sessionRevision &&
      commandId == other.commandId &&
      retireRequestKey == other.retireRequestKey &&
      nativeRetired == other.nativeRetired;

  GameStreamStopCleanupRecovery withNativeRetired() =>
      GameStreamStopCleanupRecovery(
        scope: scope,
        accountRevision: accountRevision,
        sessionId: sessionId,
        sessionRevision: sessionRevision,
        commandId: commandId,
        retireRequestKey: retireRequestKey,
        nativeRetired: true,
      );

  @override
  String toString() => 'GameStreamStopCleanupRecovery(<redacted>)';
}

final class GameStreamRevocationRecovery extends GameStreamPendingOperation {
  GameStreamRevocationRecovery({
    required this.scope,
    required this.accountRevision,
    required this.revocationId,
    required this.hostId,
    required this.hostRevision,
  }) {
    _revision(accountRevision);
    _identity(revocationId);
    _identity(hostId);
    _revision(hostRevision);
  }

  @override
  final GameStreamRecoveryScope scope;
  final int accountRevision, hostRevision;
  final String revocationId, hostId;

  @override
  Map<String, Object> toJson() => _effectJson('revoke', scope, {
    'accountRevision': accountRevision,
    'revocationId': revocationId,
    'hostId': hostId,
    'hostRevision': hostRevision,
  });

  @override
  bool sameOperation(GameStreamPendingOperation other) =>
      other is GameStreamRevocationRecovery &&
      scope.same(other.scope) &&
      revocationId == other.revocationId &&
      hostId == other.hostId &&
      hostRevision == other.hostRevision;
}

final class GameStreamRevocationPrepareRecovery
    extends GameStreamPendingOperation {
  GameStreamRevocationPrepareRecovery({
    required this.scope,
    required this.accountRevision,
    required this.requestKey,
    required this.host,
  }) {
    _revision(accountRevision);
    _requestKey(requestKey);
  }

  @override
  final GameStreamRecoveryScope scope;
  final int accountRevision;
  final String requestKey;
  final CoreGameStreamHost host;

  @override
  Map<String, Object> toJson() => _effectJson('revoke_prepare', scope, {
    'accountRevision': accountRevision,
    'requestKey': requestKey,
    'host': _hostJson(host),
  });

  @override
  bool sameOperation(GameStreamPendingOperation other) =>
      other is GameStreamRevocationPrepareRecovery &&
      scope.same(other.scope) &&
      requestKey == other.requestKey &&
      host.id == other.host.id &&
      host.revision == other.host.revision;
}

final class GameStreamRevocationReadyRecovery
    extends GameStreamPendingOperation {
  GameStreamRevocationReadyRecovery({
    required this.scope,
    required this.accountRevision,
    required this.host,
    required this.revocationId,
    required this.retiredHostRevision,
  }) {
    _revision(accountRevision);
    _identity(revocationId);
    _revision(retiredHostRevision);
  }

  @override
  final GameStreamRecoveryScope scope;
  final int accountRevision, retiredHostRevision;
  final CoreGameStreamHost host;
  final String revocationId;

  @override
  Map<String, Object> toJson() => _effectJson('revoke_ready', scope, {
    'accountRevision': accountRevision,
    'host': _hostJson(host),
    'revocationId': revocationId,
    'retiredHostRevision': retiredHostRevision,
  });

  @override
  bool sameOperation(GameStreamPendingOperation other) =>
      other is GameStreamRevocationReadyRecovery &&
      scope.same(other.scope) &&
      revocationId == other.revocationId &&
      retiredHostRevision == other.retiredHostRevision;
}

final class GameStreamRecoveryStore {
  GameStreamRecoveryStore({GameStreamRecoveryBackend? backend})
    : _backend = backend ?? SecureGameStreamRecoveryBackend();

  final GameStreamRecoveryBackend _backend;

  Future<GameStreamPendingOperation?> readStored() async {
    final raw = await _backend.read();
    if (raw == null) return null;
    if (raw.length > 8192) {
      throw const GameStreamException('invalid_recovery_record');
    }
    try {
      return _pendingOperation(jsonDecode(raw));
    } catch (_) {
      throw const GameStreamException('invalid_recovery_record');
    }
  }

  Future<GameStreamPendingOperation?> readAny(
    GameStreamRecoveryScope scope,
  ) async {
    final value = await readStored();
    return value != null && value.scope.same(scope) ? value : null;
  }

  Future<GameStreamRecoveryRecord?> read(GameStreamRecoveryScope scope) async {
    final value = await readAny(scope);
    return value is GameStreamRecoveryRecord ? value : null;
  }

  Future<void> write(GameStreamRecoveryRecord record) async {
    await writeAny(record);
  }

  Future<void> writeAny(GameStreamPendingOperation record) async {
    final encoded = jsonEncode(record.toJson());
    if (encoded.length > 8192) {
      throw const GameStreamException('invalid_recovery_record');
    }
    await _backend.write(encoded);
  }

  Future<void> clearExact(GameStreamRecoveryRecord expected) async {
    await clearAny(expected);
  }

  Future<void> clearAny(GameStreamPendingOperation expected) async {
    final raw = await _backend.read();
    if (raw == null) return;
    try {
      final current = _pendingOperation(jsonDecode(raw));
      if (expected.sameOperation(current)) {
        await _backend.delete();
      }
    } catch (_) {
      throw const GameStreamException('invalid_recovery_record');
    }
  }
}

GameStreamPendingOperation _pendingOperation(Object? raw) {
  if (raw is Map && raw['schemaVersion'] == 1) {
    return GameStreamRecoveryRecord.fromJson(raw);
  }
  final value = _map(raw, {
    'schemaVersion',
    'operationKind',
    'scope',
    'payload',
  });
  if (value['schemaVersion'] != 2 || value['operationKind'] is! String) {
    throw const GameStreamException('invalid_recovery_record');
  }
  final scope = _scope(value['scope']);
  final payload = value['payload'];
  return switch (value['operationKind']) {
    'pair' => _pairingRecovery(scope, payload),
    'catalog' => _catalogRecovery(scope, payload),
    'session_bind' => _sessionBindRecovery(scope, payload),
    'stop_cleanup' => _stopCleanupRecovery(scope, payload),
    'revoke_prepare' => _revocationPrepareRecovery(scope, payload),
    'revoke_ready' => _revocationReadyRecovery(scope, payload),
    'revoke' => _revocationRecovery(scope, payload),
    _ => throw const GameStreamException('invalid_recovery_record'),
  };
}

GameStreamSessionBindRecovery _sessionBindRecovery(
  GameStreamRecoveryScope scope,
  Object? raw,
) {
  final value = _map(raw, {
    'accountRevision',
    'sessionId',
    'sessionRevision',
    'retireRequestKey',
    'nativeRetired',
  });
  return GameStreamSessionBindRecovery(
    scope: scope,
    accountRevision: _revision(value['accountRevision']),
    sessionId: _identity(value['sessionId']),
    sessionRevision: _revision(value['sessionRevision']),
    retireRequestKey: _requestKey(value['retireRequestKey']),
    nativeRetired: _boolean(value['nativeRetired']),
  );
}

GameStreamStopCleanupRecovery _stopCleanupRecovery(
  GameStreamRecoveryScope scope,
  Object? raw,
) {
  final value = _map(raw, {
    'accountRevision',
    'sessionId',
    'sessionRevision',
    'commandId',
    'retireRequestKey',
    'nativeRetired',
  });
  return GameStreamStopCleanupRecovery(
    scope: scope,
    accountRevision: _revision(value['accountRevision']),
    sessionId: _identity(value['sessionId']),
    sessionRevision: _revision(value['sessionRevision']),
    commandId: _identity(value['commandId']),
    retireRequestKey: _requestKey(value['retireRequestKey']),
    nativeRetired: _boolean(value['nativeRetired']),
  );
}

GameStreamRecoveryScope _scope(Object? raw) {
  final value = _map(raw, {'coreId', 'homeId', 'accountId', 'familyId'});
  return GameStreamRecoveryScope(
    coreId: _identity(value['coreId']),
    homeId: _identity(value['homeId']),
    accountId: _identity(value['accountId']),
    familyId: _identity(value['familyId']),
  );
}

GameStreamPairingRecovery _pairingRecovery(
  GameStreamRecoveryScope scope,
  Object? raw,
) {
  final value = _map(raw, {
    'authority',
    'accountRevision',
    'pairingId',
    'pairingRevision',
    'pairingGrant',
    'expiresAtMillis',
    'pairingDispatched',
    'authorityRetirementPending',
    'authorityRetired',
  });
  return GameStreamPairingRecovery(
    scope: scope,
    authority: AndroidGameStreamAuthorityV2.fromJson(value['authority']),
    accountRevision: _revision(value['accountRevision']),
    pairingId: _identity(value['pairingId']),
    pairingRevision: _revision(value['pairingRevision']),
    pairingGrant: _identity(value['pairingGrant']),
    expiresAtMillis: _timestamp(value['expiresAtMillis']),
    pairingDispatched: _boolean(value['pairingDispatched']),
    authorityRetirementPending: _boolean(value['authorityRetirementPending']),
    authorityRetired: _boolean(value['authorityRetired']),
  );
}

GameStreamCatalogRecovery _catalogRecovery(
  GameStreamRecoveryScope scope,
  Object? raw,
) {
  final keys = {
    'authority',
    'accountRevision',
    'observationId',
    'observationRevision',
    'catalogGrant',
    'expiresAtMillis',
    'host',
    'catalogDispatched',
    'authorityRetirementPending',
    'authorityRetired',
  };
  final hasBinding = raw is Map && raw.containsKey('nativeBindingId');
  if (hasBinding) {
    keys.addAll({
      'nativeBindingId',
      'bindingRevision',
      'registrationRevision',
      'engineRevision',
    });
  }
  final value = _map(raw, keys);
  return GameStreamCatalogRecovery(
    scope: scope,
    authority: AndroidGameStreamAuthorityV2.fromJson(value['authority']),
    accountRevision: _revision(value['accountRevision']),
    observationId: _identity(value['observationId']),
    observationRevision: _revision(value['observationRevision']),
    catalogGrant: _identity(value['catalogGrant']),
    expiresAtMillis: _timestamp(value['expiresAtMillis']),
    host: _host(value['host']),
    catalogDispatched: _boolean(value['catalogDispatched']),
    nativeBindingId: hasBinding ? _identity(value['nativeBindingId']) : null,
    bindingRevision: hasBinding ? _revision(value['bindingRevision']) : null,
    registrationRevision: hasBinding
        ? _revision(value['registrationRevision'])
        : null,
    engineRevision: hasBinding ? _engine(value['engineRevision']) : null,
    authorityRetirementPending: _boolean(value['authorityRetirementPending']),
    authorityRetired: _boolean(value['authorityRetired']),
  );
}

GameStreamRevocationPrepareRecovery _revocationPrepareRecovery(
  GameStreamRecoveryScope scope,
  Object? raw,
) {
  final value = _map(raw, {'accountRevision', 'requestKey', 'host'});
  return GameStreamRevocationPrepareRecovery(
    scope: scope,
    accountRevision: _revision(value['accountRevision']),
    requestKey: _requestKey(value['requestKey']),
    host: _host(value['host']),
  );
}

GameStreamRevocationReadyRecovery _revocationReadyRecovery(
  GameStreamRecoveryScope scope,
  Object? raw,
) {
  final value = _map(raw, {
    'accountRevision',
    'host',
    'revocationId',
    'retiredHostRevision',
  });
  return GameStreamRevocationReadyRecovery(
    scope: scope,
    accountRevision: _revision(value['accountRevision']),
    host: _host(value['host']),
    revocationId: _identity(value['revocationId']),
    retiredHostRevision: _revision(value['retiredHostRevision']),
  );
}

GameStreamRevocationRecovery _revocationRecovery(
  GameStreamRecoveryScope scope,
  Object? raw,
) {
  final value = _map(raw, {
    'accountRevision',
    'revocationId',
    'hostId',
    'hostRevision',
  });
  return GameStreamRevocationRecovery(
    scope: scope,
    accountRevision: _revision(value['accountRevision']),
    revocationId: _identity(value['revocationId']),
    hostId: _identity(value['hostId']),
    hostRevision: _revision(value['hostRevision']),
  );
}

Map<String, Object> _effectJson(
  String kind,
  GameStreamRecoveryScope scope,
  Map<String, Object> payload,
) => {
  'schemaVersion': 2,
  'operationKind': kind,
  'scope': scope.toJson(),
  'payload': payload,
};

Map<String, Object> _hostJson(CoreGameStreamHost host) => {
  'id': host.id,
  'revision': host.revision,
  'pairingRevision': host.pairingRevision,
  'catalogRevision': host.catalogRevision,
  'name': host.name,
  'codecs': host.codecs,
};

CoreGameStreamHost _host(Object? raw) {
  const keys = {
    'id',
    'revision',
    'pairingRevision',
    'catalogRevision',
    'name',
    'codecs',
  };
  const legacyKeys = {...keys, 'maxWidth', 'maxHeight', 'maxFps'};
  if (raw is! Map || raw.keys.any((key) => key is! String)) {
    throw const GameStreamException('invalid_recovery_record');
  }
  final rawKeys = raw.keys.cast<String>().toSet();
  final current = rawKeys.length == keys.length && rawKeys.every(keys.contains);
  final legacy =
      rawKeys.length == legacyKeys.length && rawKeys.every(legacyKeys.contains);
  if (!current && !legacy) {
    throw const GameStreamException('invalid_recovery_record');
  }
  final host = raw.cast<String, dynamic>();
  if (legacy) {
    _integer(host['maxWidth'], 320, 8192);
    _integer(host['maxHeight'], 320, 8192);
    _integer(host['maxFps'], 30, 240);
  }
  final codecs = host['codecs'];
  if (codecs is! List || codecs.any((value) => value is! String)) {
    throw const GameStreamException('invalid_recovery_record');
  }
  return CoreGameStreamHost.recovery(
    id: _identity(host['id']),
    revision: _revision(host['revision']),
    pairingRevision: _revision(host['pairingRevision']),
    catalogRevision: _revision(host['catalogRevision']),
    name: _text(host['name'], 80),
    codecs: codecs.cast<String>(),
  );
}

Map<String, dynamic> _map(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.keys.any((key) => key is! String) ||
      raw.length != keys.length ||
      !raw.keys.every(keys.contains)) {
    throw const GameStreamException('invalid_recovery_record');
  }
  return raw.cast<String, dynamic>();
}

String _identity(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value)
    ? value
    : throw const GameStreamException('invalid_recovery_record');

int _revision(Object? value) =>
    value is int && value >= 1 && value <= gameStreamMaxSafeInteger
    ? value
    : throw const GameStreamException('invalid_recovery_record');

int _timestamp(Object? value) =>
    value is int && value >= 1 && value <= gameStreamMaxSafeInteger
    ? value
    : throw const GameStreamException('invalid_recovery_record');

bool _boolean(Object? value) => value is bool
    ? value
    : throw const GameStreamException('invalid_recovery_record');

int _integer(Object? value, int min, int max) =>
    value is int && value >= min && value <= max
    ? value
    : throw const GameStreamException('invalid_recovery_record');

String _text(Object? value, int max) =>
    value is String &&
        value.trim() == value &&
        value.isNotEmpty &&
        value.length <= max &&
        !value.contains(RegExp(r'[\x00-\x1f\x7f]'))
    ? value
    : throw const GameStreamException('invalid_recovery_record');

String _engine(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(value)
    ? value
    : throw const GameStreamException('invalid_recovery_record');

String _requestKey(Object? value) =>
    value is String &&
        value.length >= 16 &&
        value.length <= 128 &&
        RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)
    ? value
    : throw const GameStreamException('invalid_recovery_record');

bool _authorityScopeMatches(
  GameStreamRecoveryScope scope,
  AndroidGameStreamAuthorityV2 authority,
) =>
    scope.coreId == authority.coreId &&
    scope.homeId == authority.homeId &&
    scope.accountId == authority.accountId &&
    scope.familyId == authority.familyId;

bool _sameAuthority(
  AndroidGameStreamAuthorityV2 left,
  AndroidGameStreamAuthorityV2 right,
) =>
    left.clientInstanceId == right.clientInstanceId &&
    left.coreId == right.coreId &&
    left.homeId == right.homeId &&
    left.accountId == right.accountId &&
    left.familyId == right.familyId &&
    left.accountRevision == right.accountRevision &&
    left.pinRevision == right.pinRevision &&
    left.pinConfigured == right.pinConfigured &&
    left.pinUnlocked == right.pinUnlocked &&
    left.routeRevision == right.routeRevision &&
    left.lifecycleRevision == right.lifecycleRevision &&
    left.idleRevision == right.idleRevision &&
    left.interactionRevision == right.interactionRevision;

bool _sameHost(CoreGameStreamHost left, CoreGameStreamHost right) =>
    left.id == right.id &&
    left.revision == right.revision &&
    left.pairingRevision == right.pairingRevision &&
    left.catalogRevision == right.catalogRevision &&
    left.name == right.name &&
    left.codecs.length == right.codecs.length &&
    List<bool>.generate(
      left.codecs.length,
      (index) => left.codecs[index] == right.codecs[index],
    ).every((same) => same);
