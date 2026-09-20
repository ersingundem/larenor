import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/legal/presentation/legal_screen.dart';
import 'package:larenor/features/settings/presentation/panes/about_pane.dart';
import 'package:larenor/features/settings/presentation/panes/settings_nav_row.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

class _Connection extends ConnectionConfig {
  _Connection({this.initial});

  final HaConnectionConfig? initial;
  var signOuts = 0;
  Completer<void>? gate;
  Object? error;

  @override
  Future<HaConnectionConfig?> build() async => initial;

  void replace(HaConnectionConfig config) => state = AsyncData(config);

  @override
  Future<void> signOut() async {
    signOuts++;
    await gate?.future;
    if (error != null) throw error!;
    state = const AsyncData(null);
  }
}

Future<void> _mount(
  WidgetTester tester, {
  required Size size,
  required String language,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const AboutPane(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final size in [const Size(600, 900), const Size(1200, 900)]) {
      testWidgets(
        '$language About actions are accessible at ${size.width}px and 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          await _mount(tester, size: size, language: language);
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('about-legal-action')),
            300,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 20,
          );
          await tester.pumpAndSettle();

          expect(find.byType(SettingsPaneScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsOneWidget);
          expect(find.byType(SettingsActionTile), findsNWidgets(2));
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('about-actions-header')),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );

          final legal = find.byKey(const ValueKey('about-legal-action'));
          expect(tester.getRect(legal).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(legal).flagsCollection.isButton, isTrue);
          Focus.of(
            tester.element(
              find.descendant(of: legal, matching: find.byType(Text)),
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(find.byType(LegalScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }

  testWidgets(
    'sign out rejects expired callbacks and runs once for current authority',
    (tester) async {
      final interaction = AppInteractionController();
      final connection = _Connection();
      final router = GoRouter(
        initialLocation: '/about',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Text('Home route')),
          GoRoute(path: '/about', builder: (_, _) => const AboutPane()),
        ],
      );
      addTearDown(interaction.dispose);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [connectionConfigProvider.overrideWith(() => connection)],
          child: CupertinoApp.router(
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) =>
                AppInteractionScope(controller: interaction, child: child!),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('about-sign-out-action')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final stale = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('about-sign-out-action')),
          )
          .onPressed!;
      final staleLegal = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('about-legal-action')),
          )
          .onPressed!;
      interaction.setActive(false);
      interaction.setActive(true);
      await tester.pump();
      stale();
      staleLegal();
      await tester.pump();
      expect(connection.signOuts, 0);
      expect(find.byType(LegalScreen), findsNothing);

      connection.gate = Completer<void>();
      final current = tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('about-sign-out-action')),
          )
          .onPressed!;
      current();
      current();
      await tester.pump();
      expect(connection.signOuts, 1);
      connection.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Home route'), findsOneWidget);
      stale();
      await tester.pump();
      expect(connection.signOuts, 1);
    },
  );

  testWidgets('captured sign out cannot cross account authority', (
    tester,
  ) async {
    final interaction = AppInteractionController();
    final connection = _Connection(
      initial: const HaConnectionConfig(
        baseUrl: 'https://old.example',
        token: 'old-test-token',
      ),
    );
    final router = GoRouter(
      initialLocation: '/about',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('Home route')),
        GoRoute(path: '/about', builder: (_, _) => const AboutPane()),
      ],
    );
    addTearDown(interaction.dispose);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [connectionConfigProvider.overrideWith(() => connection)],
        child: CupertinoApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) =>
              AppInteractionScope(controller: interaction, child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('about-sign-out-action')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final stale = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('about-sign-out-action')),
        )
        .onPressed!;
    connection.replace(
      const HaConnectionConfig(
        baseUrl: 'https://new.example',
        token: 'new-test-token',
      ),
    );
    await tester.pumpAndSettle();

    stale();
    await tester.pump();

    expect(connection.signOuts, 0);
    expect(find.byType(AboutPane), findsOneWidget);

    tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('about-sign-out-action')),
        )
        .onPressed!();
    await tester.pumpAndSettle();
    expect(connection.signOuts, 1);
    expect(find.text('Home route'), findsOneWidget);
  });

  testWidgets('failed sign out stays on route and announces a safe error', (
    tester,
  ) async {
    final interaction = AppInteractionController();
    final connection = _Connection()..error = StateError('credential detail');
    final router = GoRouter(
      initialLocation: '/about',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('Home route')),
        GoRoute(path: '/about', builder: (_, _) => const AboutPane()),
      ],
    );
    addTearDown(interaction.dispose);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [connectionConfigProvider.overrideWith(() => connection)],
        child: CupertinoApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) =>
              AppInteractionScope(controller: interaction, child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('about-sign-out-action')),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('about-sign-out-action')),
        )
        .onPressed!();
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(tester.element(find.byType(AboutPane)));
    final error = find.byKey(const ValueKey('about-sign-out-error'));
    expect(find.byType(AboutPane), findsOneWidget);
    expect(find.text('Home route'), findsNothing);
    expect(find.text(l10n.commonError), findsOneWidget);
    expect(tester.getSemantics(error).flagsCollection.isLiveRegion, isTrue);
    expect(find.textContaining('credential detail'), findsNothing);
    expect(connection.signOuts, 1);
    expect(tester.takeException(), isNull);
  });
}
