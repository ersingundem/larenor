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
  test(
    'strict settings keep gateway display keyboard and clipboard bounded',
    () {
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
      expect(value.microphone, isFalse);
      expect(value.toJson()['version'], 2);
      expect(value.toJson()['microphone'], isFalse);
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
    },
  );

  test('v2 settings persist explicit microphone opt-in strictly', () {
    final value = RdpProfileSettings.fromJson(const {
      'version': 2,
      'domain': '',
      'gatewayHost': null,
      'gatewayPort': 443,
      'gatewayUsername': '',
      'displayMode': 'fitWindow',
      'keyboardLayout': 'automatic',
      'clipboardMode': 'disabled',
      'microphone': true,
    });
    expect(value.microphone, isTrue);
    expect(value.toJson()['microphone'], isTrue);
    for (final raw in [
      {...value.toJson()}..remove('microphone'),
      {...value.toJson(), 'microphone': 1},
      {...value.toJson(), 'future': false},
    ]) {
      expect(
        () => RdpProfileSettings.fromJson(raw),
        throwsA(isA<RdpFailure>()),
      );
    }
  });

  test('legacy unimplemented fixed display migrates to truthful fit', () {
    final legacy = RdpProfileSettings.fromJson(const {
      'version': 1,
      'domain': '',
      'gatewayHost': null,
      'gatewayPort': 443,
      'gatewayUsername': '',
      'displayMode': 'fixed',
      'keyboardLayout': 'automatic',
      'clipboardMode': 'disabled',
    });
    expect(legacy.displayMode, RdpDisplayMode.fitWindow);
    expect(legacy.toJson()['displayMode'], 'fitWindow');

    final fill = RdpProfileSettings.fromJson({
      ...legacy.toJson(),
      'displayMode': 'fillWindow',
    });
    expect(fill.displayMode, RdpDisplayMode.fillWindow);
    expect(fill.toJson()['displayMode'], 'fillWindow');
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
    expect(await store.readSettings(profile, isCurrent: () => true), settings);
    expect(
      await store.readCredential(profile, isCurrent: () => true),
      credential,
    );
    expect(profile.toJson().toString(), isNot(contains('secret')));
    expect(settings.toString(), isNot(contains('secret')));

    await store.deleteCredential(profile, isCurrent: () => true);
    expect(await store.readCredential(profile, isCurrent: () => true), isNull);
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
