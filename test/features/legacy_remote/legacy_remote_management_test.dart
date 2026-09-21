import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/legacy_remote/data/legacy_remote_management_api.dart';
import 'package:larenor/features/legacy_remote/data/legacy_remote_management_controller.dart';
import 'package:larenor/features/legacy_remote/domain/legacy_remote_models.dart';
import 'package:larenor/features/legacy_remote/presentation/legacy_remote_management_screen.dart';
import 'package:larenor/features/legacy_remote/presentation/legacy_remote_route.dart';
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
  Completer<LegacyRemoteCommandResult>? confirmGate;
  var previewCalls = 0;
  var confirmCalls = 0;
  var readbackCalls = 0;

  @override
  Future<List<LegacyRemoteDevice>> list(LegacyRemoteAuthority authority) =>
      listGate?.future ?? Future.value(values);

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
        status: LegacyRemoteDispatchStatus.dispatched,
        deliveryVerified: true,
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

  LegacyRemoteCommandPreview? lastPreview;
}

final class _EmptySessions implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? session) async {}
}

void main() {
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
