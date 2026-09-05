import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/server/services/presentation/server_services_screen.dart';
import 'package:larenor/features/settings/presentation/settings_gate_screen.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_services_test.dart';

void main() {
  late ServicesFixture fixture;
  final navigator = GlobalKey<NavigatorState>();

  Future<void> mount(
    WidgetTester tester, {
    bool existing = true,
    AppInteractionController? interaction,
    ValueNotifier<bool>? visible,
    bool gate = false,
    ServerRole role = ServerRole.admin,
    double width = 700,
    double scale = 1,
    String language = 'en',
    String storedKind = 'jellyfin',
    List<String> storedCredentialKeys = const ['token'],
  }) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'settings_pin': '1234'});
    fixture = ServicesFixture(role: role);
    if (existing) {
      fixture.records.add({
        ...serviceJson(),
        'kind': storedKind,
        'credentialKeys': storedCredentialKeys,
      });
    }
    await fixture.account.initialize();
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          navigatorKey: navigator,
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) {
            Widget view = MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            );
            if (interaction != null) {
              view = AppInteractionScope(controller: interaction, child: view);
            }
            return view;
          },
          home: gate
              ? const SettingsGateScreen()
              : visible == null
              ? const ServerServicesScreen()
              : ValueListenableBuilder(
                  valueListenable: visible,
                  builder: (_, enabled, _) => TickerMode(
                    enabled: enabled,
                    child: const ServerServicesScreen(),
                  ),
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
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> field(WidgetTester tester, String key, String text) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.enterText(finder, text);
    await tester.pump();
  }

  void noSecretText(WidgetTester tester) {
    expect(
      tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? '')
          .join(' '),
      isNot(contains('synthetic-service-secret')),
    );
  }

  testWidgets(
    'create, explicit check, edit-preserve, edit-clear and forget use real contract',
    (tester) async {
      await mount(tester, existing: false);
      expect(fixture.mutations, isEmpty);
      await tap(tester, 'services-add');
      await field(tester, 'service-name', 'Media');
      await field(tester, 'service-url', 'https://media.example.test');
      await field(
        tester,
        'service-credential-token',
        'synthetic-service-secret',
      );
      expect(
        tester
            .widget<CupertinoTextField>(
              find.byKey(const ValueKey('service-credential-token')),
            )
            .obscureText,
        isTrue,
      );
      await tap(tester, 'service-submit');
      expect(fixture.mutations.length, 1);
      expect(find.text('Saved · Not checked'), findsOneWidget);
      noSecretText(tester);
      await tap(tester, 'service-check-$serviceId');
      expect(find.text('Authenticated'), findsOneWidget);
      expect(fixture.mutations.length, 2);
      await tap(tester, 'service-edit-$serviceId');
      expect(
        find.byKey(const ValueKey('service-credential-token')),
        findsNothing,
      );
      await field(tester, 'service-name', 'Renamed');
      await tap(tester, 'service-submit');
      expect(
        jsonDecode(fixture.mutations.last.body).containsKey('credentials'),
        isFalse,
      );
      await tap(tester, 'service-edit-$serviceId');
      await field(tester, 'service-url', 'https://other.example.test');
      await tap(tester, 'service-submit');
      expect(find.textContaining('Choose replacement'), findsOneWidget);
      expect(fixture.mutations.length, 3);
      await tap(tester, 'service-credentials-clear');
      await tap(tester, 'service-submit');
      expect(jsonDecode(fixture.mutations.last.body)['credentials'], isEmpty);
      await tap(tester, 'service-forget-$serviceId');
      expect(find.textContaining('containers and media files'), findsOneWidget);
      expect(fixture.mutations.length, 4);
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
      await tester.pumpAndSettle();
      expect(fixture.records, hasLength(1));
      await tap(tester, 'service-forget-$serviceId');
      final confirm = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('service-confirm-forget')),
          )
          .onPressed!;
      confirm();
      confirm();
      await tester.pumpAndSettle();
      expect(fixture.mutations.length, 5);
      expect(fixture.records, isEmpty);
      noSecretText(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('revision conflict disables mutation until explicit refresh', (
    tester,
  ) async {
    await mount(tester);
    fixture.respond = (_) async => fixture.json({
      'error': {
        'code': 'revision_conflict',
        'message': 'synthetic-service-secret',
      },
    }, 409);
    await tap(tester, 'service-check-$serviceId');
    expect(find.textContaining('Refresh'), findsWidgets);
    expect(
      tester
          .widget<CupertinoButton>(find.byKey(const ValueKey('services-add')))
          .onPressed,
      isNull,
    );
    noSecretText(tester);
    fixture.respond = (request) async => fixture.serviceResponse(request);
    await tap(tester, 'services-refresh');
    expect(
      tester
          .widget<CupertinoButton>(find.byKey(const ValueKey('services-add')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('connection capacity has its own recovery message', (
    tester,
  ) async {
    await mount(tester);
    fixture.respond = (_) async => fixture.json({
      'error': {'code': 'service_limit_reached'},
    }, 409);
    await tap(tester, 'service-check-$serviceId');
    expect(find.textContaining('connection limit'), findsOneWidget);
    expect(find.textContaining('This connection changed'), findsNothing);
  });

  for (final reason in [
    'background',
    'idle',
    'hidden',
    'account',
    'pin',
    'route',
  ]) {
    testWidgets(
      '$reason clears credential drafts and expires old save action',
      (tester) async {
        final interaction = AppInteractionController();
        final visible = ValueNotifier(true);
        addTearDown(interaction.dispose);
        addTearDown(visible.dispose);
        await mount(tester, interaction: interaction, visible: visible);
        await tap(tester, 'services-add');
        await field(tester, 'service-name', 'Private service');
        await field(tester, 'service-url', 'https://media.example.test');
        await field(
          tester,
          'service-credential-token',
          'synthetic-service-secret',
        );
        final old = tester
            .widget<CupertinoButton>(
              find.byKey(const ValueKey('service-submit')),
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
          case 'hidden':
            visible.value = false;
            await tester.pump();
            visible.value = true;
          case 'account':
            await fixture.account.signOut();
          case 'pin':
            final container = ProviderScope.containerOf(
              tester.element(find.byType(ServerServicesScreen)),
            );
            await container.read(pinLockProvider.notifier).setPin('5678');
          case 'route':
            navigator.currentState!.push(
              PageRouteBuilder<void>(
                opaque: false,
                pageBuilder: (_, _, _) =>
                    const Center(child: Text('Unrelated cover')),
              ),
            );
        }
        await tester.pumpAndSettle();
        old();
        await tester.pumpAndSettle();
        expect(fixture.mutations, isEmpty);
        expect(find.byKey(const ValueKey('service-submit')), findsNothing);
        if (reason == 'route') {
          expect(find.text('Unrelated cover'), findsOneWidget);
        }
        noSecretText(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('hidden pending refresh cannot dispatch a service mutation', (
    tester,
  ) async {
    await mount(tester);
    fixture.now = fixture.now.add(const Duration(hours: 2));
    fixture.refresh = Completer<http.Response>();
    await tap(tester, 'service-check-$serviceId');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    fixture.refresh!.complete(fixture.pair());
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(fixture.mutations, isEmpty);
    expect(fixture.account.session, isNull);
  });

  testWidgets('settings entry requires PIN and members cannot open services', (
    tester,
  ) async {
    await mount(tester, gate: true);
    expect(find.byType(ServerServicesScreen), findsNothing);
    expect(fixture.adminCalls, isEmpty);
    await tester.enterText(find.byType(CupertinoTextField), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Larenor Server'));
    await tester.pumpAndSettle();
    await tap(tester, 'server-services');
    expect(find.byType(ServerServicesScreen), findsOneWidget);
    expect(fixture.adminCalls, hasLength(1));
  });

  testWidgets('member route fails closed without a services request', (
    tester,
  ) async {
    await mount(tester, role: ServerRole.member);
    expect(find.byKey(const ValueKey('services-add')), findsNothing);
    expect(fixture.adminCalls, isEmpty);
  });

  testWidgets(
    'credential replacement starts empty and sends only newly supplied values',
    (tester) async {
      await mount(tester);
      await tap(tester, 'service-edit-$serviceId');
      await tap(tester, 'service-credentials-replace');
      expect(
        tester
            .widget<CupertinoTextField>(
              find.byKey(const ValueKey('service-credential-token')),
            )
            .controller!
            .text,
        isEmpty,
      );
      final oldToken = tester
          .widget<CupertinoTextField>(
            find.byKey(const ValueKey('service-credential-token')),
          )
          .controller!;
      await field(tester, 'service-credential-token', 'discarded-token');
      await tap(tester, 'service-auth-apiKey');
      expect(oldToken.text, isEmpty);
      expect(
        find.byKey(const ValueKey('service-credential-token')),
        findsNothing,
      );
      await field(
        tester,
        'service-credential-apiKey',
        'synthetic-service-secret',
      );
      await tap(tester, 'service-submit');
      expect(jsonDecode(fixture.mutations.single.body)['credentials'], {
        'apiKey': 'synthetic-service-secret',
      });
      noSecretText(tester);
    },
  );

  testWidgets(
    'idle expires retained forget confirmation without deleting record',
    (tester) async {
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await mount(tester, interaction: interaction);
      await tap(tester, 'service-forget-$serviceId');
      final old = tester
          .widget<CupertinoDialogAction>(
            find.byKey(const ValueKey('service-confirm-forget')),
          )
          .onPressed!;
      interaction.setActive(false);
      await tester.pump();
      interaction.setActive(true);
      await tester.pumpAndSettle();
      old();
      await tester.pumpAndSettle();
      expect(fixture.mutations, isEmpty);
      expect(fixture.records, hasLength(1));
      expect(find.byType(CupertinoAlertDialog), findsNothing);
    },
  );

  testWidgets('kind chooser selects a fixed supported service', (tester) async {
    await mount(tester, existing: false, width: 320, scale: 2);
    await tap(tester, 'services-add');
    await tap(tester, 'service-kind');
    await tap(tester, 'service-kind-qbittorrent');
    await field(tester, 'service-name', 'Downloads');
    await field(tester, 'service-url', 'http://downloads.example.test:8080');
    await tap(tester, 'service-submit');
    expect(jsonDecode(fixture.mutations.single.body)['kind'], 'qbittorrent');
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet software keyboard leaves form actions reachable', (
    tester,
  ) async {
    await mount(tester, width: 1280, scale: 2, language: 'tr');
    await tap(tester, 'services-add');
    await tap(tester, 'service-kind');
    await tap(tester, 'service-kind-qbittorrent');
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pumpAndSettle();
    await field(tester, 'service-name', 'Salon medya');
    await field(tester, 'service-url', 'https://media.example.test');
    await field(tester, 'service-credential-username', 'tablet-user');
    await field(
      tester,
      'service-credential-password',
      'synthetic-service-secret',
    );
    final submit = find.byKey(const ValueKey('service-submit'));
    expect(tester.getBottomLeft(submit).dy, lessThanOrEqualTo(600));
    await tap(tester, 'service-submit');
    expect(fixture.mutations, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('Turkish list and credential form fit ${width}px at 2x', (
      tester,
    ) async {
      await mount(tester, width: width, scale: 2, language: 'tr');
      await tap(tester, 'services-add');
      await field(tester, 'service-name', 'Salon medya');
      await field(tester, 'service-url', 'https://media.example.test');
      await field(
        tester,
        'service-credential-token',
        'synthetic-service-secret',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('service-submit')));
      expect(tester.takeException(), isNull);
      noSecretText(tester);
    });
  }

  testWidgets(
    'changing kind clears secrets and uses the service API-key field',
    (tester) async {
      await mount(tester, existing: false, width: 1280);
      await tap(tester, 'services-add');
      expect(find.textContaining('Home Assistant long-lived'), findsOneWidget);
      final oldToken = tester
          .widget<CupertinoTextField>(
            find.byKey(const ValueKey('service-credential-token')),
          )
          .controller!;
      await field(tester, 'service-credential-token', 'discarded-token');
      await tap(tester, 'service-kind');
      await tap(tester, 'service-kind-sonarr');
      expect(oldToken.text, isEmpty);
      expect(
        find.byKey(const ValueKey('service-credential-token')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('service-credential-username')),
        findsNothing,
      );
      expect(find.textContaining('API key from this service'), findsOneWidget);
      await field(tester, 'service-name', 'Television');
      await field(tester, 'service-url', 'https://sonarr.example.test');
      await field(
        tester,
        'service-credential-apiKey',
        'synthetic-service-secret',
      );
      await tap(tester, 'service-submit');
      expect(jsonDecode(fixture.mutations.single.body)['credentials'], {
        'apiKey': 'synthetic-service-secret',
      });
      noSecretText(tester);
    },
  );

  testWidgets('Proxmox guide and method selection require a complete pair', (
    tester,
  ) async {
    await mount(tester, existing: false, width: 1280);
    await tap(tester, 'services-add');
    await tap(tester, 'service-kind');
    await tap(tester, 'service-kind-proxmox');
    expect(find.textContaining('user@realm!tokenid=secret'), findsOneWidget);
    await field(tester, 'service-name', 'Virtualization');
    await field(tester, 'service-url', 'https://proxmox.example.test:8006');
    await field(
      tester,
      'service-credential-token',
      'user@pve!reader=discarded',
    );
    await tap(tester, 'service-auth-usernamePassword');
    expect(
      find.byKey(const ValueKey('service-credential-token')),
      findsNothing,
    );
    await field(tester, 'service-credential-username', 'user@pve');
    await tap(tester, 'service-submit');
    expect(fixture.mutations, isEmpty);
    expect(
      find.textContaining('Enter both username and password'),
      findsOneWidget,
    );
    await field(
      tester,
      'service-credential-password',
      'synthetic-service-secret',
    );
    await tap(tester, 'service-submit');
    expect(jsonDecode(fixture.mutations.single.body)['credentials'], {
      'username': 'user@pve',
      'password': 'synthetic-service-secret',
    });
  });

  for (final kind in ['frigate', 'esphome']) {
    testWidgets(
      '$kind public check preserves unknown saved keys without soliciting secrets',
      (tester) async {
        await mount(
          tester,
          storedKind: kind,
          storedCredentialKeys: ['userId', 'token'],
          width: 1280,
        );
        await tap(tester, 'service-edit-$serviceId');
        expect(
          find.textContaining('does not send or verify credentials'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('service-saved-credential-fields')),
              )
              .data,
          contains('User ID'),
        );
        expect(
          find.byKey(const ValueKey('service-credentials-replace')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('service-credential-token')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('service-credential-password')),
          findsNothing,
        );
        await field(tester, 'service-name', 'Preserved connection');
        await tap(tester, 'service-submit');
        expect(
          jsonDecode(fixture.mutations.single.body).containsKey('credentials'),
          isFalse,
        );
        expect(fixture.records.single['credentialKeys'], ['userId', 'token']);
        await tap(tester, 'service-edit-$serviceId');
        await tap(tester, 'service-credentials-clear');
        await tap(tester, 'service-submit');
        expect(jsonDecode(fixture.mutations.last.body)['credentials'], isEmpty);
      },
    );
  }
}
