import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/health/data/connection_evidence.dart';
import 'package:larenor/features/keenetic/core_command/core_keenetic_command.dart';
import 'package:larenor/features/proxmox/core_power/proxmox_power_controller.dart';
import 'package:larenor/features/proxmox/core_power/proxmox_power_models.dart';
import 'package:larenor/features/proxmox/core_power/proxmox_power_panel.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/core_infrastructure_evidence.dart';

final class _HeldProxmoxGateway implements ProxmoxPowerGateway {
  final previewCompleter = Completer<PowerPreview>();
  int previews = 0, confirms = 0;

  @override
  Future<PowerPreview> preview(
    ProxmoxPowerTarget target,
    ProxmoxPowerAction action,
  ) {
    previews++;
    return previewCompleter.future;
  }

  @override
  Future<PowerReceipt> confirm(
    ProxmoxPowerTarget target,
    PowerPreview preview, {
    required bool highRiskConfirmed,
  }) {
    confirms++;
    throw StateError('Synthetic test never confirms');
  }

  @override
  Future<void> cancel(ProxmoxPowerTarget target, PowerPreview preview) async {}
}

final class _HeldKeeneticApi implements CoreKeeneticCommandApi {
  final previewCompleter = Completer<CoreKeeneticCommandPreview>();
  int previews = 0, confirms = 0;

  @override
  Future<CoreKeeneticCommandPreview> preview(
    CoreKeeneticCommandAction action,
    CoreKeeneticCommandTarget target,
  ) {
    previews++;
    return previewCompleter.future;
  }

  @override
  Future<CoreKeeneticConfirmResult> confirm(String previewId, String token) {
    confirms++;
    throw StateError('Synthetic test never confirms');
  }

  @override
  Future<CoreKeeneticCommandReceipt> cancel(String previewId) async =>
      const CoreKeeneticCommandReceipt(
        CoreKeeneticCommandStatus.cancelled,
        'cancelled',
      );

  @override
  Future<CoreKeeneticCommandReceipt> status(String requestId) async =>
      const CoreKeeneticCommandReceipt(
        CoreKeeneticCommandStatus.unknown,
        'unknown',
      );
}

const _proxmoxTarget = ProxmoxPowerTarget(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  resourceId: '33333333333333333333333333333333',
  userRevision: 1,
  resourceRevision: 2,
  aclRevision: 3,
  bindingId: 'binding',
  bindingRevision: 4,
  serviceId: 'service',
  serviceRevision: 5,
  guestKind: ProxmoxGuestKind.qemu,
  node: 'pve-a',
  guestId: 101,
  currentState: ProxmoxGuestState.running,
  statusRevision: 6,
  allowedActions: {
    ProxmoxPowerAction.shutdown,
    ProxmoxPowerAction.stop,
    ProxmoxPowerAction.reboot,
    ProxmoxPowerAction.reset,
    ProxmoxPowerAction.suspend,
  },
);

CoreKeeneticCommandTarget get _keeneticTarget =>
    CoreKeeneticCommandTarget.syntheticForTest(
      targetKind: 'guest_wifi',
      targetId: 'Guest',
      value: 'disabled',
    );

Widget _app(Widget child, Size size) => CupertinoApp(
  locale: const Locale('en'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
  ],
  home: MediaQuery(
    data: MediaQueryData(size: size, textScaler: const TextScaler.linear(2)),
    child: child,
  ),
);

void main() {
  test(
    'Core HTTP boundary preserves known infrastructure failures only',
    () async {
      const known = {
        'proxmox_upstream_unauthorized',
        'proxmox_upstream_unavailable',
        'keenetic_upstream_unauthorized',
        'keenetic_upstream_denied',
        'keenetic_upstream_unavailable',
      };
      for (final code in {...known, 'private_upstream_detail'}) {
        final api = LarenorServerApi(
          endpoint: ServerEndpoint('https://core.invalid'),
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'error': {'code': code},
              }),
              502,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        addTearDown(api.close);
        await expectLater(
          api.request('GET', '/synthetic-infrastructure-read'),
          throwsA(
            isA<LarenorServerException>().having(
              (error) => error.code,
              'code',
              known.contains(code) ? code : 'server_error',
            ),
          ),
        );
      }
    },
  );

  test(
    'Core evidence maps shared authority failures without inventing success',
    () {
      for (final code in ['forbidden', 'not_found']) {
        expect(
          coreInfrastructureEvidence(failure: code).condition,
          ConnectionEvidenceCondition.permissionDenied,
        );
      }
      for (final code in [
        'proxmox_upstream_unauthorized',
        'keenetic_upstream_unauthorized',
      ]) {
        expect(
          coreInfrastructureEvidence(failure: code).condition,
          ConnectionEvidenceCondition.authenticationRequired,
        );
      }
      expect(
        coreInfrastructureEvidence(failure: 'keenetic_upstream_denied')
            .condition,
        ConnectionEvidenceCondition.permissionDenied,
      );
      for (final code in [
        'proxmox_upstream_unavailable',
        'keenetic_upstream_unavailable',
        'timeout',
      ]) {
        expect(
          coreInfrastructureEvidence(failure: code).condition,
          ConnectionEvidenceCondition.offline,
        );
      }
      expect(
        coreInfrastructureEvidence(stale: true).condition,
        ConnectionEvidenceCondition.stale,
      );
      expect(
        coreInfrastructureOperationEvidence(unknown: true).condition,
        ConnectionEvidenceCondition.stale,
      );
      expect(
        coreInfrastructureOperationEvidence(succeeded: true).stage,
        ConnectionEvidenceStage.reachable,
      );
      expect(
        coreInfrastructureEvidence(transportObserved: false).stage,
        ConnectionEvidenceStage.saved,
      );
      expect(
        coreInfrastructureEvidence(transportObserved: true).stage,
        ConnectionEvidenceStage.reachable,
      );
    },
  );

  for (final size in [const Size(600, 900), const Size(1280, 900)]) {
    testWidgets(
      '${size.width.toInt()} tablet command surfaces share evidence at 2x and keep explicit keyboard actions',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final semantics = tester.ensureSemantics();
        final proxmoxApi = _HeldProxmoxGateway();
        final proxmox = ProxmoxPowerController(
          gateway: proxmoxApi,
          target: _proxmoxTarget,
          current: () => true,
        );
        await tester.pumpWidget(
          _app(
            ProxmoxPowerPanel(
              controller: proxmox,
              isAdmin: true,
              canWrite: true,
            ),
            size,
          ),
        );
        expect(
          find.byKey(const ValueKey('proxmox-operation-evidence')),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(proxmoxApi.previews, 1);
        expect(proxmoxApi.confirms, 0);
        expect(tester.takeException(), isNull);
        for (final button in tester.widgetList<CupertinoButton>(
          find.byType(CupertinoButton),
        )) {
          expect(button.minimumSize?.height ?? 0, greaterThanOrEqualTo(48));
        }
        proxmox.dispose();

        final keeneticApi = _HeldKeeneticApi();
        await tester.pumpWidget(
          _app(
            CoreKeeneticCommandPanel(
              target: _keeneticTarget,
              isAdmin: true,
              canWrite: true,
              api: keeneticApi,
            ),
            size,
          ),
        );
        expect(
          find.byKey(const ValueKey('keenetic-operation-evidence')),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(keeneticApi.previews, 1);
        expect(keeneticApi.confirms, 0);
        expect(tester.takeException(), isNull);
        for (final button in tester.widgetList<CupertinoButton>(
          find.byType(CupertinoButton),
        )) {
          expect(button.minimumSize?.height ?? 0, greaterThanOrEqualTo(48));
        }
        semantics.dispose();
      },
    );
  }
}
