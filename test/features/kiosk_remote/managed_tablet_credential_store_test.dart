import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const token = 'fixture-token-fixture-token-fixture-token-1';

ManagedTabletEnrollment enrollment() => ManagedTabletEnrollment(
  serverBaseUrl: 'https://core.invalid',
  coreId: '1' * 32,
  homeId: '2' * 32,
  accountId: '3' * 32,
  pairingId: '4' * 32,
  deviceId: '5' * 32,
  revision: 1,
  scopes: const {'read', 'control'},
  expiresAt: DateTime.utc(2030),
  token: token,
  clientId: 'larenor-${'4' * 32}',
  topicPrefix: 'larenor/${'4' * 32}',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('pairing token round-trips only through secure storage', () async {
    final store = SecureManagedTabletCredentialStore();
    final value = enrollment();

    await store.write(value);
    final restored = await store.read();

    expect(restored?.binding, value.binding);
    expect(
      restored?.credential.publicMetadata,
      value.credential.publicMetadata,
    );
    expect(restored.toString(), isNot(contains(token)));
    expect(
      await SharedPreferences.getInstance().then((p) => p.getKeys()),
      isEmpty,
    );
  });

  test('malformed secure record fails closed without echoing secret', () async {
    FlutterSecureStorage.setMockInitialValues({
      SecureManagedTabletCredentialStore.key: '{"token":"$token"}',
    });
    final store = SecureManagedTabletCredentialStore();

    await expectLater(store.read(), throwsA(isA<FormatException>()));
    expect(store.toString(), isNot(contains(token)));
  });

  test('clearIfCurrent never deletes a replacement enrollment', () async {
    final store = SecureManagedTabletCredentialStore();
    final first = enrollment();
    final replacement = ManagedTabletEnrollment(
      serverBaseUrl: first.serverBaseUrl,
      coreId: first.coreId,
      homeId: first.homeId,
      accountId: first.accountId,
      pairingId: '6' * 32,
      deviceId: first.deviceId,
      revision: 1,
      scopes: const {'read'},
      expiresAt: first.expiresAt,
      token: 'replacement-token-replacement-token-replace',
      clientId: 'larenor-${'6' * 32}',
      topicPrefix: 'larenor/${'6' * 32}',
    );
    await store.write(first);
    await store.write(replacement);

    await store.clearIfCurrent(first.binding, first.pairingId);

    expect((await store.read())?.pairingId, replacement.pairingId);
  });

  test(
    'Core authority sends token only as header and validates exact scope',
    () async {
      final value = enrollment();
      late http.Request observed;
      final authority = CoreManagedTabletAuthority(
        client: () => MockClient((request) async {
          observed = request;
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'pairingId': value.pairingId,
              'deviceId': value.deviceId,
              'pairingRevision': value.revision,
              'listenerEnabled': false,
              'commandRetainAllowed': false,
              'availabilityTopic': '${value.topicPrefix}/availability',
              'commandTopic': '${value.topicPrefix}/command',
              'ackTopic': '${value.topicPrefix}/ack',
              'sensors': [
                for (final kind in const [
                  'battery',
                  'network',
                  'app_version',
                  'app_foreground',
                  'kiosk_state',
                ])
                  {
                    'kind': kind,
                    'stateTopic': '${value.topicPrefix}/sensor/$kind/state',
                    'retained': true,
                  },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await authority.verify(value.binding, value);

      expect(observed.url.query, isEmpty);
      expect(observed.url.toString(), isNot(contains(token)));
      expect(observed.headers['X-Larenor-Pairing-Token'], token);
      expect(observed.headers['authorization'], isNull);
    },
  );

  test('Core revoke is a typed terminal authority result', () async {
    final value = enrollment();
    final authority = CoreManagedTabletAuthority(
      client: () => MockClient((_) async => http.Response('', 401)),
    );

    await expectLater(
      authority.verify(value.binding, value),
      throwsA(isA<ManagedTabletRevoked>()),
    );
  });
}
