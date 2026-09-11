import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_provider_commands/presentation/server_music_provider_commands_screen.dart';
import 'package:larenor/features/server/music_retained/presentation/server_music_retained_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_music_retained_test_support.dart';
import 'server_music_retained_status_test.dart' show retainedJson;

void main() {
  testWidgets('member sees the admin boundary without an inventory request', (
    tester,
  ) async {
    final fixture = MusicRetainedFixture(role: ServerRole.member);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMusicRetainedScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(fixture.adminCalls, isEmpty);
    expect(find.byKey(const ValueKey('music-retained-refresh')), findsNothing);
  });

  testWidgets('attention states remain distinct from failures', (tester) async {
    final fixture = MusicRetainedFixture();
    final body = retainedJson();
    body['state'] = 'partial';
    final installation =
        (body['installations'] as List).single as Map<String, dynamic>;
    installation['state'] = 'partial';
    installation['installationState'] = 'needs_attention';
    installation['errorCode'] = 'provider_not_ready';
    final provider =
        (installation['providers'] as List).single as Map<String, dynamic>;
    provider['state'] = 'needs_attention';
    fixture.respond = (request) async =>
        request.url.path.endsWith('/music-assistant/retained')
        ? fixture.json(body)
        : fixture.defaultResponse(request);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMusicRetainedScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Setup is partial'), findsNWidgets(3));
    expect(find.text('Verification failed'), findsNothing);
    expect(
      find.byKey(ValueKey('music-provider-command-${'d' * 32}')),
      findsNothing,
    );
    expect(fixture.mutations, isEmpty);
  });

  testWidgets('ready retained provider opens commands with exact revisions', (
    tester,
  ) async {
    final fixture = MusicRetainedFixture();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMusicRetainedScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final providerId = 'd' * 32;
    final manage = find.byKey(ValueKey('music-provider-command-$providerId'));
    await tester.ensureVisible(manage);
    await tester.pumpAndSettle();
    await tester.tap(manage);
    await tester.pumpAndSettle();

    final screen = tester.widget<ServerMusicProviderCommandsScreen>(
      find.byType(ServerMusicProviderCommandsScreen),
    );
    expect(screen.target?.installationId, 'a' * 32);
    expect(screen.target?.installationRevision, 4);
    expect(screen.target?.providerSetupId, providerId);
    expect(screen.target?.providerRevision, 3);
    expect(screen.target?.providerDomain, 'spotify');
    expect(
      find.byKey(const ValueKey('provider-enable-preview')),
      findsOneWidget,
    );
    expect(fixture.mutations, isEmpty, reason: 'navigation cannot auto-review');
  });

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('retained status fits $locale tablet/DeX $width at 2x', (
        tester,
      ) async {
        final fixture = MusicRetainedFixture();
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
        await fixture.account.initialize();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              serverAccountControllerProvider.overrideWithValue(
                fixture.account,
              ),
            ],
            child: CupertinoApp(
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const ServerMusicRetainedScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Spotify'), findsOneWidget);
        final refresh = find.byKey(const ValueKey('music-retained-refresh'));
        await tester.ensureVisible(refresh);
        expect(refresh.hitTestable(), findsOneWidget);
        final size = tester.getSize(refresh);
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        expect(find.byType(CupertinoTextField), findsNothing);
        expect(fixture.mutations, isEmpty);
        fixture.account.dispose();
      });
    }
  }
}
