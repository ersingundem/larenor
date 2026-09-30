import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_provider_setup/data/server_music_provider_setup_controller.dart';
import 'package:larenor/features/server/music_provider_setup/domain/server_music_provider_setup_models.dart';
import 'package:larenor/features/server/music_manager/presentation/server_music_manager_screen.dart';
import 'package:larenor/features/server/music_provider_setup/presentation/server_music_provider_setup_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_music_manager_test_support.dart';

final class _FileStore implements ServerSessionPersistence {
  _FileStore(this.path);

  final File path;

  @override
  Future<ServerSession?> read() async => path.existsSync()
      ? ServerSession.decodeStorage(await path.readAsString())
      : null;

  @override
  Future<void> write(ServerSession? session) async {
    if (session == null) {
      if (path.existsSync()) await path.delete();
      return;
    }
    await path.parent.create(recursive: true);
    await path.writeAsString(session.encodeStorage(), flush: true);
  }
}

Future<void> _waitFor(
  bool Function() ready, {
  String reason = 'condition',
}) async {
  for (var index = 0; index < 200 && !ready(); index++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: reason);
}

void main() {
  final phase = Platform.environment['LARENOR_PRODUCT_PROVIDER_PHASE'];
  final coreUrl = Platform.environment['LARENOR_PRODUCT_PROVIDER_CORE_URL'];
  final installationId =
      Platform.environment['LARENOR_PRODUCT_PROVIDER_INSTALLATION_ID'];
  final sessionFile =
      Platform.environment['LARENOR_PRODUCT_PROVIDER_SESSION_FILE'];
  final installationRevision = int.tryParse(
    Platform.environment['LARENOR_PRODUCT_PROVIDER_INSTALLATION_REVISION'] ??
        '',
  );
  final fixtureReady =
      (phase == 'prepare' || phase == 'restart') &&
      coreUrl != null &&
      installationId != null &&
      sessionFile != null &&
      installationRevision != null &&
      installationRevision > 0;
  setUpAll(() => HttpOverrides.global = null);

  test(
    'real Client restores and completes provider setup through private worker',
    () async {
      final account = ServerAccountController(
        store: _FileStore(File(sessionFile!)),
      );
      addTearDown(account.dispose);
      if (phase == 'prepare') {
        await account.signIn(
          baseUrl: coreUrl!,
          username: 'admin',
          password: 'Synthetic new password 2026',
          deviceName: 'PRODUCT.PROVIDERS $phase',
        );
      } else {
        await account.initialize();
      }
      expect(account.failure, isNull);
      expect(account.session?.user.canAdminister, isTrue);

      final ids = <String>[if (phase == 'prepare') 'a' * 32 else 'b' * 32]
          .iterator;
      final controller = ServerMusicProviderSetupController(
        account,
        installationId: installationId!,
        installationRevision: installationRevision!,
        requestId: () {
          if (!ids.moveNext()) throw StateError('request id exhausted');
          return ids.current;
        },
      );
      addTearDown(controller.dispose);
      await controller.loadCapabilities(current: () => true);
      expect(controller.failure, isNull);
      expect(
        controller.capabilities?.providers
            .map((provider) => provider.domain)
            .toList(),
        [
          ServerMusicProviderDomain.spotify,
          ServerMusicProviderDomain.appleMusic,
          ServerMusicProviderDomain.youtubeMusic,
        ],
      );

      if (phase == 'prepare') {
        await controller.create(
          ServerMusicProviderDomain.youtubeMusic,
          current: () => true,
        );
        expect(controller.reconciled, isTrue);
        expect(controller.createOutcomeUnknown, isFalse);
        for (
          var attempt = 0;
          attempt < 100 &&
              controller.setup?.state !=
                  ServerMusicProviderSetupState.actionRequired;
          attempt++
        ) {
          if (!controller.busy) {
            await controller.refresh(current: () => true);
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          controller.setup?.state,
          ServerMusicProviderSetupState.actionRequired,
        );
        expect(
          controller.setup?.domain,
          ServerMusicProviderDomain.youtubeMusic,
        );
        expect(
          controller.setup?.interaction,
          ServerMusicProviderSetupInteraction.submitForm,
        );
        expect(
          controller.setup?.fields
              .singleWhere((field) => field.key == 'cookie')
              .type,
          ServerMusicProviderSetupFieldType.secureString,
        );
        return;
      }

      expect(phase, 'restart');
      await _waitFor(
        () =>
            controller.setup?.state ==
            ServerMusicProviderSetupState.actionRequired,
        reason: 'active setup did not survive Core and Client restart',
      );
      await controller.submit(
        ServerMusicProviderSetupSubmission({
          'username': 'fixture-family',
          'cookie': 'SAPISID=product-provider-private-cookie',
          'po_token_server_url': 'http://127.0.0.1:8096',
        }),
        current: () => true,
      );
      expect(controller.failure, isNull);
      expect(controller.setup?.state, ServerMusicProviderSetupState.ready);
      expect(controller.setup?.providerInstanceId, 'ytmusic--owned-fixture');
      expect(controller.toString(), isNot(contains('private-cookie')));

      await controller.create(
        ServerMusicProviderDomain.spotify,
        current: () => true,
      );
      for (
        var attempt = 0;
        attempt < 100 &&
            controller.setup?.state !=
                ServerMusicProviderSetupState.actionRequired;
        attempt++
      ) {
        if (!controller.busy) await controller.refresh(current: () => true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(controller.setup?.domain, ServerMusicProviderDomain.spotify);
      expect(controller.setup?.externalUrl?.scheme, 'https');
      expect(controller.setup?.externalUrl?.host, 'accounts.spotify.com');
      await controller.cancel(current: () => true);
      expect(controller.failure, isNull);
      expect(controller.setup?.state, ServerMusicProviderSetupState.cancelled);

      await account.signOut();
      expect(controller.capabilities, isNull);
      expect(controller.setup, isNull);
    },
    skip: fixtureReady ? false : 'Run with server/tests/support/product_music_provider_flutter_acceptance.py.',
  );

  testWidgets(
    'verified admin can reach provider onboarding from music center',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fixture = MusicManagerFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1100);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverAccountControllerProvider.overrideWithValue(fixture.account),
          ],
          child: const CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ServerMusicManagerScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final verify = find.byKey(const ValueKey('music-manager-verify'));
      await tester.ensureVisible(verify);
      await tester.tap(verify);
      await tester.pumpAndSettle();
      final setup = find.byKey(const ValueKey('music-manager-provider-setup'));
      await tester.ensureVisible(setup);
      await tester.tap(setup);
      await tester.pumpAndSettle();
      expect(find.byType(ServerMusicProviderSetupScreen), findsOneWidget);
    },
  );
}
