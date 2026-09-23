import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/data/legacy_jellyfin_track_preferences_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = JellyfinConfig(
  baseUrl: 'https://private-jellyfin.invalid/root',
  userId: 'private-user-id',
  accessToken: 'private-access-token',
  deviceId: 'private-device-id',
);

String _legacyKey(JellyfinConfig config) {
  final scope = sha256.convert(
    utf8.encode('${config.baseUrl}\u0000${config.userId}'),
  );
  return 'jellyfin_track_languages_v1_$scope';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'previews normalized legacy choices without exposing source secrets',
    () async {
      final raw = jsonEncode({'version': 1, 'audio': 'tur', 'subtitle': 'off'});
      SharedPreferences.setMockInitialValues({_legacyKey(_config): raw});

      final preview = await LegacyJellyfinTrackPreferencesPreviewReader().read(
        _config,
        isCurrent: () => true,
      );

      expect(preview?.audioLanguage, 'tr');
      expect(preview?.subtitleLanguage, 'off');
      expect(preview.toString(), 'Legacy Jellyfin track preference preview');
      expect(preview.toString(), isNot(contains(_config.baseUrl)));
      expect(preview.toString(), isNot(contains(_config.userId)));
      expect(preview.toString(), isNot(contains(_config.accessToken)));
      expect(
        (await SharedPreferences.getInstance()).getString(_legacyKey(_config)),
        raw,
        reason: 'preview must not silently import or delete the legacy record',
      );
    },
  );

  test(
    'binds lookup to endpoint and user but never to the access token',
    () async {
      SharedPreferences.setMockInitialValues({
        _legacyKey(_config): jsonEncode({
          'version': 1,
          'audio': 'en',
          'subtitle': null,
        }),
      });
      final reader = LegacyJellyfinTrackPreferencesPreviewReader();

      expect(
        await reader.read(
          JellyfinConfig(
            baseUrl: _config.baseUrl,
            userId: _config.userId,
            accessToken: 'replacement-token',
            deviceId: 'replacement-device',
          ),
          isCurrent: () => true,
        ),
        isNotNull,
      );
      expect(
        await reader.read(
          JellyfinConfig(
            baseUrl: 'https://other.invalid',
            userId: _config.userId,
            accessToken: _config.accessToken,
            deviceId: _config.deviceId,
          ),
          isCurrent: () => true,
        ),
        isNull,
      );
      expect(
        await reader.read(
          JellyfinConfig(
            baseUrl: _config.baseUrl,
            userId: 'other-user',
            accessToken: _config.accessToken,
            deviceId: _config.deviceId,
          ),
          isCurrent: () => true,
        ),
        isNull,
      );
    },
  );

  test('fails closed for malformed, incompatible and empty records', () async {
    final invalid = <Object?>[
      '{',
      jsonEncode({'version': 2, 'audio': 'en', 'subtitle': null}),
      jsonEncode({
        'version': 1,
        'audio': 'en',
        'subtitle': null,
        'token': 'must-not-be-accepted',
      }),
      jsonEncode({'version': 1, 'audio': '../en', 'subtitle': null}),
      jsonEncode({'version': 1, 'audio': null, 'subtitle': null}),
      'x' * 129,
      42,
    ];

    for (final raw in invalid) {
      SharedPreferences.setMockInitialValues({_legacyKey(_config): raw!});
      expect(
        await LegacyJellyfinTrackPreferencesPreviewReader().read(
          _config,
          isCurrent: () => true,
        ),
        isNull,
        reason: '$raw',
      );
    }
  });

  test(
    'retires a preview when authority changes during storage read',
    () async {
      SharedPreferences.setMockInitialValues({
        _legacyKey(_config): jsonEncode({
          'version': 1,
          'audio': 'en',
          'subtitle': null,
        }),
      });
      var checks = 0;

      await expectLater(
        LegacyJellyfinTrackPreferencesPreviewReader().read(
          _config,
          isCurrent: () => ++checks < 3,
        ),
        throwsStateError,
      );
    },
  );
}
