import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';
import 'package:larenor/features/remote_access/rdp/rdp_models.dart';
import 'package:larenor/features/remote_access/rdp/rdp_security_store.dart';

import 'rdp_models_test.dart' show profile;

Future<RdpSecurityStore> savedProfile(FlutterSecureStorage storage) async {
  final profiles = RemoteProfilesStore(storage: storage);
  final empty = await profiles.read(isCurrent: () => true);
  await profiles.replace(empty, [profile], isCurrent: () => true);
  return RdpSecurityStore(storage: storage, profiles: profiles);
}

void main() {
  test('strict settings keep gateway display keyboard and clipboard bounded', () {
    final value = RdpProfileSettings.fromJson(const {
      'version': 1,
      'domain': 'LARENOR',
      'gatewayHost': 'gateway.home.arpa',
      'gatewayPort': 443,
      'gatewayUsername': 'ersin',
      'displayMode': 'fitWindow',
      'keyboardLayout': 'turkishQ',
      'clipboardMode': 'clientToRemote',
    });
    expect(value.domain, 'LARENOR');
    expect(value.gatewayHost, 'gateway.home.arpa');
    expect(value.gatewayPort, 443);
    expect(value.keyboardLayout, RdpKeyboardLayout.turkishQ);
    expect(value.clipboardMode, RdpClipboardMode.clientToRemote);
    expect(value.toJson(), isNot(contains('password')));
    expect(
      () => RdpProfileSettings.fromJson({
        ...value.toJson(),
        'gatewayHost': 'https://gateway.home.arpa/path',
      }),
      throwsA(isA<RdpFailure>()),
    );
    expect(
      () => RdpProfileSettings.fromJson({
        ...value.toJson(),
        'clipboardMode': 'unrestricted',
      }),
      throwsA(isA<RdpFailure>()),
    );
  });

  test('settings and credentials are profile-bound secure records', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final store = await savedProfile(storage);
    const settings = RdpProfileSettings(
      domain: 'LARENOR',
      gatewayHost: 'gateway.home.arpa',
      gatewayPort: 443,
      gatewayUsername: 'gateway-user',
      displayMode: RdpDisplayMode.fitWindow,
      keyboardLayout: RdpKeyboardLayout.turkishQ,
      clipboardMode: RdpClipboardMode.clientToRemote,
    );
    const credential = RdpCredential(
      password: 'secret-rdp-password',
      gatewayPassword: 'secret-gateway-password',
    );

    await store.saveSettings(profile, settings, isCurrent: () => true);
    await store.saveCredential(profile, credential, isCurrent: () => true);
    expect(
      await store.readSettings(profile, isCurrent: () => true),
      settings,
    );
    expect(
      await store.readCredential(profile, isCurrent: () => true),
      credential,
    );
    expect(profile.toJson().toString(), isNot(contains('secret')));
    expect(settings.toString(), isNot(contains('secret')));

    await store.deleteCredential(profile, isCurrent: () => true);
    expect(
      await store.readCredential(profile, isCurrent: () => true),
      isNull,
    );
  });

  test('credential validation rejects controls and oversized secrets', () {
    expect(
      () => RdpCredential(password: 'bad\u0000password').validate(),
      throwsA(isA<RdpFailure>()),
    );
    expect(
      () => RdpCredential(password: 'a' * 4097).validate(),
      throwsA(isA<RdpFailure>()),
    );
  });
}
