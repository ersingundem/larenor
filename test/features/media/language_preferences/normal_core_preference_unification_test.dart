import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/media/language_preferences/data/core_media_language_preferences_api.dart';

class _Store implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;
  @override
  Future<void> write(ServerSession? value) async {}
}

void main() {
  final url = Platform.environment['LARENOR_F24_CORE_URL'];
  setUpAll(() => HttpOverrides.global = null);
  test(
    'actual Client legacy write changes the player preference and vice versa',
    () async {
      final account = ServerAccountController(store: _Store());
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: url!,
        username: 'admin',
        password: 'Synthetic new password 2026',
        deviceName: 'Language preference gate',
      );
      expect(account.failure, isNull);
      await account.withSession((transport, session) async {
        final context = session.context!;
        final legacy =
            '/media/jellyfin/preferences/${context.coreId}/${context.homeId}';
        await transport.request(
          'PUT',
          legacy,
          token: session.accessToken,
          body: {
            'schemaVersion': 1,
            'expectedRevision': 0,
            'audioLanguage': 'zh-hant-tw',
            'subtitleLanguage': 'off',
          },
        );
        final player = CoreMediaLanguagePreferencesApi(
          transport,
          session.accessToken,
          context,
          session.user.id,
          session.sessionFamilyId!,
        );
        final observed = await player.read();
        expect(observed.preference!.audioLanguage, 'zh-hant-tw');
        expect(observed.preference!.revision, 1);
        await player.save(
          base: observed,
          requestId: 'e' * 32,
          audioLanguage: 'en',
          subtitleLanguage: null,
        );
        final reverse = await transport.request(
          'GET',
          legacy,
          token: session.accessToken,
        );
        final preference = reverse!['preference'] as Map;
        expect(preference['audioLanguage'], 'en');
        expect(preference['revision'], 2);
      });
    },
    skip: url == null ? 'Requires explicit isolated normal Core runner' : false,
  );
}
