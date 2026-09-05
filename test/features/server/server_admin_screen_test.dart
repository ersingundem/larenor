import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/server/admin/presentation/server_admin_screen.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'server_admin_test_support.dart';

void main() {
  late AdminFixture fixture;
  late GlobalKey<NavigatorState> navigation;

  setUp(() {
    fixture = AdminFixture();
    navigation = GlobalKey<NavigatorState>();
  });

  Future<void> mount(
    WidgetTester tester, {
    double width = 600,
    double scale = 1,
    String language = 'en',
    AppInteractionController? interaction,
    ValueNotifier<bool>? visible,
  }) async {
    await tester.runAsync(fixture.account.initialize);
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = Size(width, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          navigatorKey: navigation,
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: interaction == null
                ? child!
                : AppInteractionScope(controller: interaction, child: child!),
          ),
          home: visible == null
              ? const ServerAdminScreen()
              : ValueListenableBuilder<bool>(
                  valueListenable: visible,
                  builder: (_, value, child) =>
                      TickerMode(enabled: value, child: child!),
                  child: const ServerAdminScreen(),
                ),
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
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    final target = find.byKey(ValueKey(key));
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        250,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('admin-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
    }
    await tester.ensureVisible(target);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> enterCreate(WidgetTester tester) async {
    await tap(tester, 'admin-create');
    await tester.enterText(
      find.byKey(const ValueKey('admin-username')),
      'member2',
    );
    await tester.enterText(
      find.byKey(const ValueKey('admin-temporary-password')),
      adminPassword,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
  }

  void noSecretText(WidgetTester tester) {
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((item) => item.data ?? '')
        .join('\n');
    expect(text, isNot(contains(adminPassword)));
    expect(text, isNot(contains('synthetic_admin_access')));
  }

  testWidgets('current members cannot load administrator data', (tester) async {
    fixture.account.dispose();
    await tester.runAsync(() async {
      fixture = AdminFixture(role: ServerRole.member);
    });
    await mount(tester);
    expect(fixture.adminCalls, isEmpty);
    expect(find.byKey(const ValueKey('admin-create')), findsNothing);
  });

  testWidgets(
    'create requires confirmation and duplicate submit sends one request',
    (tester) async {
      await mount(tester);
      await enterCreate(tester);
      expect(fixture.mutations, isEmpty);
      final password = tester.widget<CupertinoTextField>(
        find.byKey(const ValueKey('admin-temporary-password')),
      );
      expect(password.obscureText, isTrue);
      noSecretText(tester);
      final submit = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('admin-submit-user')),
          )
          .onPressed!;
      submit();
      submit();
      await tester.pumpAndSettle();
      expect(fixture.mutations.length, 1);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      noSecretText(tester);
    },
  );

  testWidgets(
    'cancelled secret draft and retained submit callback never publish',
    (tester) async {
      await mount(tester);
      await enterCreate(tester);
      final submit = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('admin-submit-user')),
          )
          .onPressed!;
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
      await tester.pumpAndSettle();
      submit();
      await tester.pumpAndSettle();
      expect(fixture.mutations, isEmpty);
      await tap(tester, 'admin-create');
      expect(
        tester
            .widget<CupertinoTextField>(
              find.byKey(const ValueKey('admin-temporary-password')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'own password reset disabled and last administrator conflict requires refresh',
    (tester) async {
      await mount(tester);
      expect(
        tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('admin-reset-$adminId')),
            )
            .onPressed,
        isNull,
      );
      await tap(tester, 'admin-edit-$adminId');
      await tap(tester, 'admin-access-role-member');
      fixture.respond = (_) async => fixture.json({
        'error': {'code': 'last_active_admin'},
      }, 409);
      await tap(tester, 'admin-submit-access');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Keep at least one enabled administrator.'),
        findsOneWidget,
      );
      expect(fixture.mutations.length, 1);
      expect(
        tester
            .widget<CupertinoButton>(find.byKey(const ValueKey('admin-create')))
            .onPressed,
        isNull,
      );
      fixture.respond = null;
      await tap(tester, 'admin-refresh');
      expect(
        tester
            .widget<CupertinoButton>(find.byKey(const ValueKey('admin-create')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('session revoke stays read-only until explicit confirmation', (
    tester,
  ) async {
    await mount(tester);
    await tap(tester, 'admin-tab-sessions');
    await tap(tester, 'admin-revoke-$deviceId');
    expect(fixture.mutations, isEmpty);
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
    await tester.pumpAndSettle();
    expect(fixture.mutations, isEmpty);
    await tap(tester, 'admin-revoke-$deviceId');
    final submit = tester
        .widget<CupertinoDialogAction>(
          find.byKey(const ValueKey('admin-confirm-revoke')),
        )
        .onPressed!;
    submit();
    submit();
    await tester.pumpAndSettle();
    expect(fixture.mutations.length, 1);
    expect(find.text('Revoked'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final reason in ['background', 'idle', 'pin', 'account', 'hidden']) {
    testWidgets(
      '$reason clears secret dialog and invalidates retained confirmation',
      (tester) async {
        final interaction = AppInteractionController();
        final visible = ValueNotifier(true);
        addTearDown(interaction.dispose);
        addTearDown(visible.dispose);
        await mount(tester, interaction: interaction, visible: visible);
        await enterCreate(tester);
        final submit = tester
            .widget<CupertinoDialogAction>(
              find.byKey(const ValueKey('admin-submit-user')),
            )
            .onPressed!;
        switch (reason) {
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            await tester.pump();
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          case 'idle':
            interaction.setActive(false);
            await tester.pump();
            interaction.setActive(true);
          case 'pin':
            final container = ProviderScope.containerOf(
              tester.element(find.byType(ServerAdminScreen)),
            );
            await container.read(pinLockProvider.notifier).setPin('2468');
          case 'account':
            await tester.runAsync(fixture.account.signOut);
          case 'hidden':
            visible.value = false;
            await tester.pump();
            visible.value = true;
        }
        await tester.pumpAndSettle();
        submit();
        await tester.pumpAndSettle();
        expect(find.byType(CupertinoAlertDialog), findsNothing);
        expect(fixture.mutations, isEmpty);
        expect(find.byKey(const ValueKey('admin-create')), findsNothing);
        noSecretText(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'unrelated nonopaque route expires old access without popping the cover',
    (tester) async {
      await mount(tester);
      final create = tester
          .widget<CupertinoButton>(find.byKey(const ValueKey('admin-create')))
          .onPressed!;
      final covered = navigation.currentState!.push<void>(
        PageRouteBuilder(
          opaque: false,
          pageBuilder: (_, _, _) =>
              const Center(child: Text('Independent cover')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Independent cover'), findsOneWidget);
      navigation.currentState!.pop();
      await covered;
      await tester.pumpAndSettle();
      create();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(fixture.mutations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background during refresh prevents dispatch and acceptance of stale auth',
    (tester) async {
      await mount(tester);
      await enterCreate(tester);
      fixture.now = fixture.now.add(const Duration(hours: 2));
      fixture.refresh = Completer();
      await tap(tester, 'admin-submit-user');
      // Rotation now durably stores its intent before dispatching the POST.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(fixture.store.value?.authMutationPending, isTrue);
      expect(
        fixture.calls
            .where((request) => request.url.path.endsWith('/auth/refresh'))
            .length,
        1,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      fixture.refresh!.complete(fixture.pair());
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(fixture.mutations, isEmpty);
      expect(fixture.account.session, isNull);
      expect(fixture.store.value, isNull);
      expect(find.byKey(const ValueKey('admin-create')), findsNothing);
    },
  );

  testWidgets(
    'covering an owned secret dialog expires it while preserving the independent route',
    (tester) async {
      await mount(tester);
      await enterCreate(tester);
      final submit = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('admin-submit-user')),
          )
          .onPressed!;
      final covered = navigation.currentState!.push<void>(
        PageRouteBuilder(
          opaque: false,
          pageBuilder: (_, _, _) =>
              const Center(child: Text('Independent cover')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Independent cover'), findsOneWidget);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      navigation.currentState!.pop();
      await covered;
      await tester.pumpAndSettle();
      submit();
      await tester.pumpAndSettle();
      expect(fixture.mutations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final dimensions in [(320.0, 2.0), (1280.0, 1.6)]) {
    testWidgets(
      'Turkish administrator lists and forms fit ${dimensions.$1}px ${dimensions.$2}x',
      (tester) async {
        await mount(
          tester,
          width: dimensions.$1,
          scale: dimensions.$2,
          language: 'tr',
        );
        await tap(tester, 'admin-create');
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        navigation.currentState!.pop();
        await tester.pumpAndSettle();
        await tap(tester, 'admin-tab-sessions');
        await tap(tester, 'admin-revoke-$deviceId');
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        noSecretText(tester);
      },
    );
  }
}
