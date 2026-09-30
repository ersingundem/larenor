import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/game_streaming/data/core_game_stream_api.dart';

Map<String, dynamic> _map(Object? value) => (value! as Map<String, dynamic>);

void _exactKeys(Object? raw, Set<String> expected) {
  final value = _map(raw);
  expect(value.keys.toSet(), expected);
}

void main() {
  test('shared F60 v2 fixture conforms to every public Client DTO', () {
    final fixture = _map(
      jsonDecode(
        File('docs/contracts/f60-game-streaming-v2.json').readAsStringSync(),
      ),
    );
    expect(fixture['schemaVersion'], 2);
    final limits = _map(fixture['limits']);
    expect(limits['maxSafeInteger'], gameStreamMaxSafeInteger);
    expect(limits['minApps'], 0);
    expect(limits['maxApps'], 256);

    final pairing = _map(fixture['pairingIntent']);
    final pairingCreate = _map(pairing['create']);
    _exactKeys(pairingCreate['request'], {
      'schemaVersion',
      'requestKey',
      'accountRevision',
      'expiresAt',
    });
    final intent = CoreGameStreamPairingIntent.fromJson(
      _map(pairingCreate['response']),
    );
    expect(intent.pairingGrant, isNotNull);
    final pairingComplete = _map(pairing['complete']);
    _exactKeys(pairingComplete['request'], {
      'schemaVersion',
      'expectedPairingRevision',
      'pairingGrant',
      'observation',
    });
    final pairingResponse = _map(pairingComplete['response']);
    final host = CoreGameStreamHost.fromJson(pairingResponse['host']);
    final pairingApps = pairingResponse['apps']! as List;
    expect(
      pairingApps
          .map((value) => CoreGameStreamApp.fromJson(value, hostId: host.id))
          .length,
      1,
    );
    _exactKeys(pairingResponse['registrationMapping'], {
      'nativeReceiptId',
      'hostId',
      'apps',
    });

    final catalog = _map(fixture['catalog']);
    final catalogResponse = _map(catalog['response']);
    expect(
      (catalogResponse['apps']! as List)
          .map((value) => CoreGameStreamApp.fromJson(value, hostId: host.id))
          .length,
      1,
    );
    final refresh = _map(catalog['refresh']);
    final refreshCreate = _map(refresh['create']);
    _exactKeys(refreshCreate['request'], {
      'schemaVersion',
      'requestKey',
      'expectedHostRevision',
      'expectedPairingRevision',
      'expectedCatalogRevision',
      'accountRevision',
      'expiresAt',
    });
    final catalogIntent = CoreGameStreamCatalogIntent.fromJson(
      _map(refreshCreate['firstResponseOnly']),
      hostId: host.id,
    );
    expect(catalogIntent.catalogGrant, isNotNull);
    final refreshComplete = _map(refresh['complete']);
    _exactKeys(refreshComplete['request'], {
      'schemaVersion',
      'expectedObservationRevision',
      'catalogGrant',
      'observation',
    });
    final refreshResponse = _map(refreshComplete['response']);
    _exactKeys(refreshResponse, {
      'schemaVersion',
      'hostRevision',
      'pairingRevision',
      'catalogRevision',
      'apps',
      'registrationMapping',
    });

    final session = _map(fixture['session']);
    final sessionOpen = _map(session['open']);
    _exactKeys(sessionOpen['request'], {
      'schemaVersion',
      'requestKey',
      'expectedHostRevision',
      'expectedPairingRevision',
      'expectedCatalogRevision',
      'expectedAppRevision',
      'accountRevision',
      'clientAuthority',
      'expiresAt',
      'selectedQuality',
    });
    final opened = CoreGameStreamSession.fromJson(sessionOpen['response']);
    expect(
      opened.selectedQuality.toJson(),
      _map(sessionOpen['request'])['selectedQuality'],
    );
    expect(
      CoreGameStreamSession.fromJson(_map(session['read'])['response']).id,
      opened.id,
    );
    expect(
      CoreGameStreamSession.fromJson(_map(session['retire'])['response']).state,
      'retired',
    );

    final command = _map(fixture['command']);
    final authorize = _map(command['authorize']);
    _exactKeys(authorize['request'], {
      'schemaVersion',
      'requestKey',
      'expectedSessionRevision',
      'intent',
    });
    final first = _map(authorize['firstResponseOnly']);
    expect(
      CoreGameStreamCommand.fromJson(
        first['command'],
        sessionId: opened.id,
      ).state,
      'authorized',
    );
    expect(
      CoreGameStreamCommand.fromJson(
        _map(command['read'])['response'],
        sessionId: opened.id,
      ).state,
      'authorized',
    );
    final commandComplete = _map(command['complete']);
    _exactKeys(commandComplete['request'], {
      'schemaVersion',
      'expectedSessionRevision',
      'dispatchGrant',
      'state',
      'result',
      'observationKind',
      'readbackRevision',
      'nativeReceiptDigest',
    });
    expect(
      CoreGameStreamCommand.fromJson(
        commandComplete['response'],
        sessionId: opened.id,
      ).state,
      'native_observed',
    );

    final revocation = _map(fixture['revocation']);
    final revokeCreate = _map(revocation['create']);
    _exactKeys(revokeCreate['request'], {
      'schemaVersion',
      'requestKey',
      'expectedHostRevision',
      'expectedPairingRevision',
      'expectedCatalogRevision',
    });
    final retired = CoreGameStreamRevocation.fromJson(
      revokeCreate['response'],
      hostId: host.id,
    );
    expect(retired.state, 'core_retired');
    final revokeComplete = _map(revocation['complete']);
    _exactKeys(revokeComplete['request'], {
      'schemaVersion',
      'state',
      'readbackRevision',
      'nativeReceiptDigest',
    });
    final cleared = CoreGameStreamRevocation.fromJson(
      revokeComplete['response'],
      hostId: host.id,
    );
    expect(cleared.state, 'local_cleared');
    expect(cleared.readbackRevision, 13);
    expect(cleared.nativeReceiptDigest, 'f' * 64);

    expect(
      fixture['privacy'].toString(),
      isNot(anyOf(contains('privateKeyValue'), contains('pinValue'))),
    );
  });
}
