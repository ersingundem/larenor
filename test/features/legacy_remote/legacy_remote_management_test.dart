import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/legacy_remote/data/legacy_remote_management_api.dart';
import 'package:larenor/features/legacy_remote/data/legacy_remote_management_controller.dart';
import 'package:larenor/features/legacy_remote/domain/legacy_remote_models.dart';
import 'package:larenor/features/legacy_remote/presentation/legacy_remote_management_screen.dart';
import 'package:larenor/features/legacy_remote/presentation/legacy_remote_route.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/features/settings/presentation/settings_split_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _authority = LegacyRemoteAuthority(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: '33333333333333333333333333333333',
  sessionFamilyId: '44444444444444444444444444444444',
  routeId: '56565656565656565656565656565656',
  homeRevision: 4,
  accountRevision: 8,
  memberRevision: 6,
  sessionRevision: 3,
  routeRevision: 2,
);

const _command = LegacyRemoteCommandDefinition(
  bindingId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  key: LegacyRemoteCommandKey.powerToggle,
  maxRepeats: 1,
  maxHoldMs: 0,
);

bool _alwaysCurrent() => true;

LegacyRemoteDevice _device({
  bool stored = true,
  bool reachable = true,
  bool providerVerified = true,
}) => LegacyRemoteDevice(
  authority: _authority,
  deviceId: '55555555555555555555555555555555',
  name: 'Living room TV',
  deviceRevision: 7,
  providerType: LegacyRemoteProvider.homeAssistant,
  providerId: '77777777777777777777777777777777',
  providerRevision: 3,
  bridgeId: '66666666666666666666666666666666',
  bridgeRevision: 2,
  protocol: LegacyRemoteProtocol.ir,
  profileId: '88888888888888888888888888888888',
  profileRevision: 5,
  codeSetId: '99999999999999999999999999999999',
  codeSetRevision: 9,
  stored: stored,
  reachable: reachable,
  providerVerified: providerVerified,
  commands: const [_command],
);

final class _Api implements LegacyRemoteManagementApi {
  List<LegacyRemoteDevice> values = [_device()];
  Completer<List<LegacyRemoteDevice>>? listGate;
  final listGates = <Completer<List<LegacyRemoteDevice>>>[];
  Completer<LegacyRemoteCommandResult>? confirmGate;
  var previewCalls = 0;
  var confirmCalls = 0;
  var readbackCalls = 0;
  bool uncertain = false;

  @override
  Future<List<LegacyRemoteDevice>> list(LegacyRemoteAuthority authority) =>
      listGates.isNotEmpty
      ? listGates.removeAt(0).future
      : listGate?.future ?? Future.value(values);

  @override
  Future<LegacyRemoteCommandPreview> preview(
    LegacyRemoteAuthority authority, {
    required LegacyRemoteDevice device,
    required LegacyRemoteCommandDefinition command,
    required int repeats,
    required int holdMs,
  }) async {
    previewCalls++;
    return LegacyRemoteCommandPreview(
      authority: authority,
      requestId: '0123456789abcdef0123456789abcdef',
      deviceId: device.deviceId,
      deviceRevision: device.deviceRevision,
      providerType: device.providerType,
      providerId: device.providerId,
      providerRevision: device.providerRevision,
      bridgeId: device.bridgeId,
      bridgeRevision: device.bridgeRevision,
      profileId: device.profileId,
      profileRevision: device.profileRevision,
      codeSetId: device.codeSetId,
      codeSetRevision: device.codeSetRevision,
      bindingId: command.bindingId,
      key: command.key,
      repeats: repeats,
      holdMs: holdMs,
      expiresAt: DateTime.utc(2030),
      confirmationToken: 'b' * 64,
    );
  }

  LegacyRemoteCommandResult _result(LegacyRemoteCommandPreview preview) =>
      LegacyRemoteCommandResult(
        preview: preview,
        status: uncertain
            ? LegacyRemoteDispatchStatus.uncertain
            : LegacyRemoteDispatchStatus.dispatched,
        deliveryVerified: !uncertain,
        deviceStateVerified: false,
      );

  @override
  Future<LegacyRemoteCommandResult> confirm(
    LegacyRemoteAuthority authority,
    LegacyRemoteCommandPreview preview,
  ) {
    confirmCalls++;
    return confirmGate?.future ?? Future.value(_result(preview));
  }

  @override
  Future<LegacyRemoteCommandResult> readback(
    LegacyRemoteAuthority authority, {
    required String requestId,
  }) async {
    readbackCalls++;
    return _result(lastPreview!);
  }

  @override
  Future<LegacyRemoteLearningResult> learn(
    LegacyRemoteAuthority authority, {
    required LegacyRemoteDevice device,
    required LegacyRemoteCommandKey key,
  }) async => LegacyRemoteLearningResult(
    requestId: 'fedcba9876543210fedcba9876543210',
    device: device,
    key: key,
    status: LegacyRemoteLearningStatus.uncertain,
    learningVerified: false,
    bindingId: null,
    profileRevision: null,
    codeSetRevision: null,
  );

  LegacyRemoteCommandPreview? lastPreview;
}

final class _EmptySessions implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? session) async {}
}

http.Response _jsonResponse(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

final class _SourceApi implements LegacyRemoteSourceSetupApi {
  var configureCalls = 0;

  static const service = LegacyRemoteSetupService(
    serviceId: 'abababababababababababababababab',
    name: 'Home Assistant',
    revision: 4,
  );

  @override
  Future<List<LegacyRemoteSetupService>> setupServices() async => const [
    service,
  ];

  @override
  Future<List<LegacyRemoteSourceBinding>> listSources() async => const [];

  @override
  Future<LegacyRemoteSourceBinding> configureSource({
    required LegacyRemoteSetupService service,
    required String name,
    required String entityId,
    required String learnedDeviceName,
    required LegacyRemoteCommandKey commandKey,
    required String learnedCommandName,
  }) async {
    configureCalls++;
    expect(service, same(_SourceApi.service));
    expect(name, 'Living room TV');
    expect(entityId, 'remote.living_room_broadlink');
    expect(learnedDeviceName, 'television');
    expect(commandKey, LegacyRemoteCommandKey.powerToggle);
    expect(learnedCommandName, 'power');
    return const LegacyRemoteSourceBinding(
      sourceId: 'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd',
      revision: 1,
      serviceId: 'abababababababababababababababab',
      serviceRevision: 4,
      name: 'Living room TV',
      entityId: 'remote.living_room_broadlink',
      commandKeys: [LegacyRemoteCommandKey.powerToggle],
      configurationTag:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
  }
}

void main() {
  test(
    'uncertain delivery and learning are visible and never auto-replayed',
    () async {
      final api = _Api()..uncertain = true;
      final controller = LegacyRemoteManagementController(
        api: api,
        authority: _authority,
        isCurrent: () => true,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final device = controller.devices.single;
      await controller.preview(device, _command);
      api.lastPreview = controller.pendingPreview;
      await controller.confirmPending();
      expect(controller.state, LegacyRemoteManagementState.uncertain);
      expect(controller.lastResult?.deliveryVerified, isFalse);
      await controller.confirmPending();
      expect(api.confirmCalls, 1);
      expect(api.readbackCalls, 1);
      await controller.load();
      await controller.learn(
        controller.devices.single,
        LegacyRemoteCommandKey.powerToggle,
      );
      expect(controller.state, LegacyRemoteManagementState.uncertain);
      expect(controller.lastLearning?.learningVerified, isFalse);
    },
  );
  test('late device list cannot clear a newer verified list', () async {
    final api = _Api();
    final controller = LegacyRemoteManagementController(
      api: api,
      authority: _authority,
      isCurrent: () => true,
    );
    addTearDown(controller.dispose);
    final older = Completer<List<LegacyRemoteDevice>>();
    final newer = Completer<List<LegacyRemoteDevice>>();
    api.listGates.addAll([older, newer]);

    final firstLoad = controller.load();
    final secondLoad = controller.load();
    newer.complete([_device()]);
    await secondLoad;
    expect(controller.state, LegacyRemoteManagementState.ready);
    expect(controller.devices, hasLength(1));

    older.complete([]);
    await firstLoad;
    expect(controller.state, LegacyRemoteManagementState.ready);
    expect(controller.devices, hasLength(1));
  });

  test(
    'safe device and command state rejects private or stale authority',
    () async {
      var current = true;
      final api = _Api();
      final controller = LegacyRemoteManagementController(
        api: api,
        authority: _authority,
        isCurrent: () => current,
      );
      addTearDown(controller.dispose);

      await controller.load();
      final device = controller.devices.single;
      expect(device.stored, isTrue);
      expect(device.reachable, isTrue);
      expect(device.providerVerified, isTrue);
      expect(device.commands, const [_command]);
      expect(device.toString(), isNot(contains('raw')));
      await controller.preview(device, _command, repeats: 2);
      expect(api.previewCalls, 0);

      api.values = [_device(providerVerified: false)];
      await controller.load();
      await controller.preview(controller.devices.single, _command);
      expect(api.previewCalls, 0);

      final gate = Completer<List<LegacyRemoteDevice>>();
      api.listGate = gate;
      final late = controller.load();
      current = false;
      gate.complete([_device()]);
      await late;
      expect(controller.devices, isEmpty);
      expect(controller.state, LegacyRemoteManagementState.stale);
    },
  );

  testWidgets(
    'normal Home Assistant source setup and named IR learning are bounded',
    (tester) async {
      final api = _Api();
      final sourceApi = _SourceApi();
      final controller = LegacyRemoteManagementController(
        api: api,
        authority: _authority,
        isCurrent: () => true,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        CupertinoApp(
          home: LegacyRemoteManagementScreen(
            controller: controller,
            sourceSetup: sourceApi,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey(
            'legacy-remote-learn-55555555555555555555555555555555',
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('legacy-remote-add-source')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('legacy-remote-source-name')),
        'Living room TV',
      );
      await tester.enterText(
        find.byKey(const ValueKey('legacy-remote-source-entity')),
        'remote.living_room_broadlink',
      );
      await tester.enterText(
        find.byKey(const ValueKey('legacy-remote-source-device')),
        'television',
      );
      await tester.enterText(
        find.byKey(const ValueKey('legacy-remote-source-command')),
        'power',
      );
      await tester.tap(find.byKey(const ValueKey('legacy-remote-source-save')));
      await tester.pumpAndSettle();

      expect(sourceApi.configureCalls, 1);
      expect(
        find.byKey(const ValueKey('legacy-remote-add-source')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('legacy-remote-add-source')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('legacy-remote-source-cancel')),
      );
      await tester.pumpAndSettle();
      expect(sourceApi.configureCalls, 1);
      expect(
        find.byKey(const ValueKey('legacy-remote-add-source')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'active route keeps its real Core authority while source setup is inline',
    (tester) async {
      const coreId = '11111111111111111111111111111111';
      const homeId = '22222222222222222222222222222222';
      const accountId = '33333333333333333333333333333333';
      const familyId = '44444444444444444444444444444444';
      const serviceId = 'abababababababababababababababab';
      String? savedSourceId;
      var configured = 0;
      final account = ServerAccountController(
        store: _EmptySessions(),
        apiFactory: (endpoint) => LarenorServerApi(
          endpoint: endpoint,
          client: MockClient((request) async {
            final path = request.url.path;
            if (request.method == 'POST' && path.endsWith('/auth/login')) {
              return _jsonResponse({
                'accessToken': 'a' * 43,
                'refreshToken': 'b' * 43,
                'expiresIn': 3600,
                'sessionFamilyId': familyId,
                'user': {
                  'id': accountId,
                  'username': 'admin',
                  'role': 'admin',
                  'mustChangePassword': false,
                },
              });
            }
            if (request.headers['authorization'] != 'Bearer ${'a' * 43}') {
              return _jsonResponse({
                'error': {'code': 'unauthorized'},
              }, 401);
            }
            if (request.method == 'GET' && path.endsWith('/context')) {
              return _jsonResponse({
                'schemaVersion': 1,
                'coreId': coreId,
                'homeId': homeId,
              });
            }
            if (request.method == 'GET' &&
                path.endsWith('/admin/legacy-remotes/$coreId/$homeId')) {
              return _jsonResponse({
                'catalog': {
                  'schemaVersion': 1,
                  'authority': {
                    'schemaVersion': 1,
                    'coreId': coreId,
                    'homeId': homeId,
                    'homeRevision': 3,
                    'accountId': accountId,
                    'accountRevision': 5,
                    'memberRevision': 7,
                    'sessionFamilyId': familyId,
                    'active': true,
                    'canControlLegacyRemote': true,
                  },
                  'items': const [],
                },
              });
            }
            if (request.method == 'GET' && path.endsWith('/admin/services')) {
              return _jsonResponse({
                'services': [
                  {
                    'id': serviceId,
                    'name': 'Home Assistant',
                    'kind': 'home_assistant',
                    'baseUrl': 'https://ha.invalid',
                    'revision': 4,
                    'credentialKeys': ['token'],
                    'verification': {
                      'state': 'authenticated',
                      'checkedAt': '2026-09-30T12:00:00Z',
                      'version': '2026.9.2',
                    },
                  },
                ],
              });
            }
            if (request.method == 'GET' && path.endsWith('/sources')) {
              return _jsonResponse({
                'schemaVersion': 1,
                'sources': savedSourceId == null
                    ? const []
                    : [
                        {
                          'sourceId': savedSourceId,
                          'revision': 1,
                          'serviceId': serviceId,
                          'serviceRevision': 4,
                          'name': 'Living room TV',
                          'entityId': 'remote.living_room_broadlink',
                          'protocol': 'ir',
                          'commandKeys': ['power_toggle'],
                          'configurationTag': 'd' * 64,
                        },
                      ],
              });
            }
            if (request.method == 'PUT' && path.contains('/sources/')) {
              configured++;
              savedSourceId = request.url.pathSegments.last;
              expect(savedSourceId, matches(RegExp(r'^[0-9a-f]{32}$')));
              expect(jsonDecode(request.body), {
                'schemaVersion': 1,
                'expectedRevision': 0,
                'serviceId': serviceId,
                'expectedServiceRevision': 4,
                'name': 'Living room TV',
                'entityId': 'remote.living_room_broadlink',
                'learnedDeviceName': 'television',
                'protocol': 'ir',
                'commands': [
                  {
                    'key': 'power_toggle',
                    'commandName': 'power',
                    'maxRepeats': 1,
                  },
                ],
              });
              return _jsonResponse({
                'schemaVersion': 1,
                'sourceId': savedSourceId,
                'revision': 1,
                'configurationTag': 'd' * 64,
              });
            }
            throw StateError('unexpected route ${request.method} $path');
          }),
        ),
      );
      addTearDown(account.dispose);
      await account.signIn(
        baseUrl: 'https://core.invalid',
        username: 'admin',
        password: 'synthetic-password',
        deviceName: 'tablet',
      );
      expect(account.session, isNotNull);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverAccountControllerProvider.overrideWithValue(account),
          ],
          child: const CupertinoApp(
            home: LegacyRemoteRoute(gateCurrent: _alwaysCurrent),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('legacy-remote-add-source')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('legacy-remote-add-source')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('legacy-remote-source-name')),
        'Living room TV',
      );
      await tester.enterText(
        find.byKey(const ValueKey('legacy-remote-source-entity')),
        'remote.living_room_broadlink',
      );
      await tester.enterText(
        find.byKey(const ValueKey('legacy-remote-source-device')),
        'television',
      );
      await tester.enterText(
        find.byKey(const ValueKey('legacy-remote-source-command')),
        'power',
      );
      await tester.tap(find.byKey(const ValueKey('legacy-remote-source-save')));
      await tester.pumpAndSettle();

      expect(configured, 1);
      expect(
        find.byKey(const ValueKey('legacy-remote-add-source')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('legacy-remote-route-retry')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'command requires preview confirmation and exact delivery readback',
    () async {
      var current = true;
      final api = _Api();
      final controller = LegacyRemoteManagementController(
        api: api,
        authority: _authority,
        isCurrent: () => current,
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.preview(controller.devices.single, _command);
      api.lastPreview = controller.pendingPreview;
      expect(controller.pendingPreview, isNotNull);
      expect(controller.pendingPreview.toString(), isNot(contains('b' * 64)));
      expect(api.confirmCalls, 0);

      final gate = Completer<LegacyRemoteCommandResult>();
      api.confirmGate = gate;
      final late = controller.confirmPending();
      current = false;
      gate.complete(api._result(api.lastPreview!));
      await late;
      expect(controller.state, LegacyRemoteManagementState.stale);
      expect(api.readbackCalls, 0);

      current = true;
      api.confirmGate = null;
      await controller.load();
      await controller.preview(controller.devices.single, _command);
      api.lastPreview = controller.pendingPreview;
      await controller.confirmPending();
      expect(controller.state, LegacyRemoteManagementState.verified);
      expect(controller.lastResult!.deliveryVerified, isTrue);
      expect(controller.lastResult!.deviceStateVerified, isFalse);
      expect(api.confirmCalls, 2);
      expect(api.readbackCalls, 1);
    },
  );

  for (final language in ['en', 'tr']) {
    for (final size in [const Size(600, 900), const Size(1280, 900)]) {
      testWidgets('$language remote is accessible at ${size.width}px and 2x', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        final api = _Api();
        final controller = LegacyRemoteManagementController(
          api: api,
          authority: _authority,
          isCurrent: () => true,
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          CupertinoApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: LegacyRemoteManagementScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AppSurface), findsOneWidget);
        expect(find.byType(SettingsSection), findsAtLeastNWidgets(2));
        final action = find.byKey(
          const ValueKey(
            'legacy-remote-55555555555555555555555555555555-powerToggle',
          ),
        );
        expect(tester.getRect(action).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(action).flagsCollection.isButton, isTrue);
        expect(
          tester
              .getSemantics(
                find.byKey(
                  const ValueKey(
                    'legacy-remote-state-55555555555555555555555555555555',
                  ),
                ),
              )
              .label,
          contains(
            language == 'tr'
                ? 'Cihaz durumu doğrulanmadı'
                : 'Device state not verified',
          ),
        );
        expect(tester.takeException(), isNull);

        Focus.of(
          tester.element(
            find.descendant(of: action, matching: find.byType(Text)),
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        api.lastPreview = controller.pendingPreview;
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(api.confirmCalls, 0);

        final confirm = find.byKey(
          const ValueKey('legacy-remote-confirm-action'),
        );
        expect(tester.getRect(confirm).height, greaterThanOrEqualTo(48));
        Focus.of(
          tester.element(
            find.descendant(of: confirm, matching: find.byType(Text)),
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(api.confirmCalls, 1);
        expect(api.readbackCalls, 1);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        '$language settings discovers remote route at $width and 2x',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final semantics = tester.ensureSemantics();
          final interaction = AppInteractionController();
          final account = ServerAccountController(store: _EmptySessions());
          addTearDown(interaction.dispose);
          addTearDown(account.dispose);
          final title = language == 'tr'
              ? 'Akıllı kumandalar'
              : 'Smart remotes';

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                serverAccountControllerProvider.overrideWithValue(account),
              ],
              child: CupertinoApp(
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: AppInteractionScope(
                    controller: interaction,
                    child: child!,
                  ),
                ),
                home: SettingsSplitScreen(remoteGateCurrent: () => true),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final entryText = find.text(title).first;
          await tester.ensureVisible(entryText);
          final entry = find.ancestor(
            of: entryText,
            matching: find.byType(CupertinoButton),
          );
          expect(tester.getRect(entry).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(entry).flagsCollection.isButton, isTrue);
          Focus.of(tester.element(entryText)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(find.byType(LegacyRemoteRoute), findsOneWidget);
          final retry = find.byKey(const ValueKey('legacy-remote-route-retry'));
          expect(retry, findsOneWidget);
          expect(tester.getRect(retry).height, greaterThanOrEqualTo(48));
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }
}
