import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/music_provider_commands/presentation/server_music_provider_commands_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_music_provider_command_test_support.dart';

const target = ServerMusicProviderCommandTarget(
  installationId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  installationRevision: 4,
  providerSetupId: 'cccccccccccccccccccccccccccccccc',
  providerRevision: 3,
  providerDomain: 'spotify',
);

void main() {
  late ProviderCommandFixture fixture;

  Future<void> mount(
    WidgetTester tester, {
    ServerMusicProviderCommandTarget? selected = target,
    String language = 'en',
    double width = 1280,
    ServerRole role = ServerRole.admin,
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    fixture = ProviderCommandFixture(role: role);
    await fixture.account.initialize();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          theme: larenorTheme(brightness: Brightness.light),
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ServerMusicProviderCommandsScreen(target: selected),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.account.dispose();
    });
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        'explicit provider authority is tablet safe $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          addTearDown(semantics.dispose);
          await mount(tester, language: language, width: width);
          expect(tester.takeException(), isNull);
          expect(find.byType(CupertinoTextField), findsNothing);
          final disable = find.byKey(
            const ValueKey('provider-disable-preview'),
          );
          expect(tester.getSize(disable).height, greaterThanOrEqualTo(48));
          expect(
            tester
                .getSemantics(disable)
                .getSemanticsData()
                .hasAction(ui.SemanticsAction.tap),
            isTrue,
          );
          await tap(tester, 'provider-disable-preview');
          expect(fixture.providerPosts, hasLength(1));
          expect(find.byKey(const ValueKey('provider-confirm')), findsOneWidget);
          expect(fixture.providerPosts, hasLength(1), reason: 'no auto-confirm');
          await tap(tester, 'provider-confirm');
          expect(fixture.providerPosts, hasLength(2));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('keyboard can review and confirm without replay', (tester) async {
    await mount(tester);
    final disable = find.byKey(const ValueKey('provider-disable-preview'));
    Focus.of(tester.element(disable)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fixture.providerPosts, hasLength(1));
    final confirm = find.byKey(const ValueKey('provider-confirm'));
    await tester.ensureVisible(confirm);
    Focus.of(tester.element(confirm)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(fixture.providerPosts, hasLength(2));
  });

  testWidgets('busy double tap creates one preview and never confirms', (
    tester,
  ) async {
    await mount(tester);
    fixture.previewResponse = Completer();
    final disable = find.byKey(const ValueKey('provider-disable-preview'));
    await tester.tap(disable);
    await tester.pump();
    await tester.tap(disable, warnIfMissed: false);
    await tester.pump();
    expect(fixture.providerPosts, hasLength(1));
    fixture.previewResponse!.complete(
      fixture.json({'preview': providerCommandPreviewJson()}, 201),
    );
    await tester.pumpAndSettle();
    expect(fixture.providerPosts, hasLength(1));
    expect(find.byKey(const ValueKey('provider-confirm')), findsOneWidget);
  });

  for (final boundary in ['background', 'route', 'pin', 'account']) {
    testWidgets('$boundary discards a late preview without retry', (
      tester,
    ) async {
      await mount(tester);
      fixture.previewResponse = Completer();
      await tester.tap(
        find.byKey(const ValueKey('provider-disable-preview')),
      );
      await tester.pump();
      expect(fixture.providerPosts, hasLength(1));
      switch (boundary) {
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        case 'route':
          Navigator.of(tester.element(find.byType(CupertinoPageScaffold))).push(
            CupertinoPageRoute<void>(
              builder: (_) => const CupertinoPageScaffold(
                child: Text('Covered'),
              ),
            ),
          );
        case 'pin':
          final container = ProviderScope.containerOf(
            tester.element(find.byType(ServerMusicProviderCommandsScreen)),
          );
          await container.read(pinLockProvider.notifier).setPin('5678');
        case 'account':
          await fixture.account.signOut();
      }
      await tester.pump();
      fixture.previewResponse!.complete(
        fixture.json({'preview': providerCommandPreviewJson()}, 201),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('provider-confirm')), findsNothing);
      expect(fixture.providerPosts, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  }

  testWidgets('unbound entry point exposes no command mutation', (tester) async {
    await mount(tester, selected: null);
    expect(find.byKey(const ValueKey('provider-enable-preview')), findsNothing);
    expect(fixture.providerPosts, isEmpty);
  });

  testWidgets('member entry point exposes no command mutation', (tester) async {
    await mount(tester, role: ServerRole.member);
    expect(find.byKey(const ValueKey('provider-enable-preview')), findsNothing);
    expect(fixture.providerPosts, isEmpty);
  });
}
