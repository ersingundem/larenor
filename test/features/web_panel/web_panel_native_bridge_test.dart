import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/web_panel/domain/web_panel_native_bridge.dart';
import 'package:larenor/features/web_panel/data/web_panel_native_runtime.dart';
import 'package:larenor/features/web_panel/data/web_panel_renderer_monitor.dart';

const scope = WebPanelBridgeScope(
  coreId: 'core-main',
  homeId: 'home-main',
  accountId: 'account-admin',
  sessionFamily: 'session-family',
  sourceId: 'panel-kitchen',
  sourceRevision: 7,
  policyRevision: 11,
  routeEpoch: 13,
  lifecycleEpoch: 17,
  topOrigin: 'https://panel.example',
);

WebPanelBridgeTrustedFrame frame({
  WebPanelBridgeScope binding = scope,
  String topOrigin = 'https://panel.example',
  bool mainFrame = true,
  bool newWindow = false,
  bool foreground = true,
  bool routeVisible = true,
}) => WebPanelBridgeTrustedFrame(
  binding: binding,
  topOrigin: topOrigin,
  mainFrame: mainFrame,
  newWindow: newWindow,
  foreground: foreground,
  routeVisible: routeVisible,
);

String command({
  int sequence = 1,
  String requestId = '0123456789abcdef0123456789abcdef',
  String grantId = 'abcdef0123456789abcdef0123456789',
  String method = 'speak',
  Map<String, Object?> payload = const {
    'text': 'Dinner is ready',
    'locale': 'en-US',
  },
}) => jsonEncode({
  'schemaVersion': 1,
  'sequence': sequence,
  'requestId': requestId,
  'grantId': grantId,
  'method': method,
  'payload': payload,
});

final class Port implements WebPanelNativeBridgePort {
  Port({
    this.outcome = WebPanelNativePortOutcome.accepted,
    this.observed = true,
    this.gate,
  });

  final WebPanelNativePortOutcome outcome;
  final bool observed;
  final Completer<void>? gate;
  int revision = 1;
  int executes = 0, readbacks = 0;
  WebPanelNativeCommand? lastCommand;

  @override
  Set<WebPanelNativeMethod> get capabilities => {
    WebPanelNativeMethod.speak,
    WebPanelNativeMethod.printDocument,
  };

  @override
  int get capabilityRevision => revision;

  @override
  Future<WebPanelNativePortResult> execute(
    WebPanelNativeCommand value,
    WebPanelBridgeTrustedFrame trusted,
  ) async {
    executes++;
    lastCommand = value;
    await gate?.future;
    return WebPanelNativePortResult(
      outcome: outcome,
      receiptHandle: outcome == WebPanelNativePortOutcome.accepted
          ? 'receipt-local-1'
          : null,
    );
  }

  @override
  Future<bool> readback(
    String receiptHandle,
    WebPanelNativeCommand value,
    WebPanelBridgeTrustedFrame trusted,
  ) async {
    readbacks++;
    return observed;
  }
}

void main() {
  test(
    'strict v1 allowlist rejects unknown methods and unbounded payloads',
    () {
      final parsed = WebPanelNativeCommand.parse(command());
      expect(parsed.method, WebPanelNativeMethod.speak);
      expect(parsed.sequence, 1);
      expect(parsed.payload, {'text': 'Dinner is ready', 'locale': 'en-US'});

      for (final invalid in [
        command(method: 'shell'),
        command(payload: {'text': 'x' * 501}),
        command(payload: {'text': 'ok', 'secret': 'token'}),
        jsonEncode({
          'schemaVersion': 2,
          'sequence': 1,
          'requestId': '0123456789abcdef0123456789abcdef',
          'grantId': 'abcdef0123456789abcdef0123456789',
          'method': 'speak',
          'payload': {'text': 'ok'},
        }),
        '${command()} trailing',
      ]) {
        expect(
          () => WebPanelNativeCommand.parse(invalid),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );

  test('one-shot grant requires an exact trusted HTTPS main-frame binding', () {
    final controller = WebPanelNativeBridgeController(
      port: Port(),
      isCurrent: (candidate) => candidate == scope,
      grantIds: () => 'abcdef0123456789abcdef0123456789',
      previewIds: () => 'fedcba9876543210fedcba9876543210',
    );
    controller.arm(WebPanelNativeMethod.speak, scope);

    for (final rejected in [
      frame(mainFrame: false),
      frame(newWindow: true),
      frame(topOrigin: 'http://panel.example'),
      frame(topOrigin: 'https://foreign.example'),
      frame(
        binding: const WebPanelBridgeScope(
          coreId: 'core-main',
          homeId: 'home-main',
          accountId: 'account-admin',
          sessionFamily: 'session-family',
          sourceId: 'panel-kitchen',
          sourceRevision: 8,
          policyRevision: 11,
          routeEpoch: 13,
          lifecycleEpoch: 17,
          topOrigin: 'https://panel.example',
        ),
      ),
      frame(routeVisible: false),
      frame(foreground: false),
    ]) {
      expect(
        controller.preview(command(), rejected).status,
        WebPanelBridgeStatus.denied,
      );
    }

    final preview = controller.preview(command(), frame());
    expect(preview.status, WebPanelBridgeStatus.needsConfirmation);
    expect(preview.previewId, 'fedcba9876543210fedcba9876543210');
    expect(
      controller.preview(command(), frame()).status,
      WebPanelBridgeStatus.denied,
    );

    controller.revoke();
    expect(
      controller.confirm(preview, frame()),
      completion(
        isA<WebPanelBridgeReceipt>().having(
          (value) => value.status,
          'status',
          WebPanelBridgeStatus.denied,
        ),
      ),
    );
  });

  test(
    'confirmed command executes once and lost acknowledgement never replays',
    () async {
      final gate = Completer<void>();
      final port = Port(gate: gate, observed: false);
      final controller = WebPanelNativeBridgeController(
        port: port,
        isCurrent: (candidate) => candidate == scope,
        grantIds: () => 'abcdef0123456789abcdef0123456789',
        previewIds: () => 'fedcba9876543210fedcba9876543210',
      );
      controller.arm(WebPanelNativeMethod.speak, scope);
      final preview = controller.preview(command(), frame());
      final pending = controller.confirm(preview, frame());
      final concurrent = await controller.confirm(preview, frame());
      expect(concurrent.status, WebPanelBridgeStatus.unconfirmed);
      expect(port.executes, 1);

      gate.complete();
      final receipt = await pending;
      expect(receipt.status, WebPanelBridgeStatus.unconfirmed);
      expect(port.executes, 1);
      expect(port.readbacks, 1);
      expect(
        (await controller.confirm(preview, frame())).status,
        WebPanelBridgeStatus.unconfirmed,
      );
      expect(port.executes, 1);

      final public = jsonEncode(receipt.toPublicJson());
      expect(public, contains('0123456789abcdef0123456789abcdef'));
      expect(public, isNot(contains('Dinner is ready')));
      expect(public, isNot(contains('abcdef0123456789abcdef0123456789')));
      expect(public, isNot(contains('receipt-local-1')));

      controller.arm(WebPanelNativeMethod.speak, scope);
      expect(
        controller.preview(command(sequence: 3), frame()).status,
        WebPanelBridgeStatus.denied,
      );
    },
  );
  test(
    'unsupported capability and timed out native port fail closed',
    () async {
      final unsupported = WebPanelNativeBridgeController(
        port: const UnsupportedWebPanelNativeBridgePort(),
        isCurrent: (candidate) => candidate == scope,
        grantIds: () => 'abcdef0123456789abcdef0123456789',
        previewIds: () => 'fedcba9876543210fedcba9876543210',
      );
      unsupported.arm(WebPanelNativeMethod.scanQr, scope);
      expect(
        unsupported
            .preview(command(method: 'scanQr', payload: const {}), frame())
            .status,
        WebPanelBridgeStatus.unsupported,
      );

      final port = Port(gate: Completer<void>());
      final timed = WebPanelNativeBridgeController(
        port: port,
        isCurrent: (candidate) => candidate == scope,
        grantIds: () => 'abcdef0123456789abcdef0123456789',
        previewIds: () => 'fedcba9876543210fedcba9876543210',
        portTimeout: const Duration(milliseconds: 1),
      );
      timed.arm(WebPanelNativeMethod.speak, scope);
      final preview = timed.preview(command(), frame());
      final receipt = await timed.confirm(preview, frame());
      expect(receipt.status, WebPanelBridgeStatus.unconfirmed);
      expect(port.executes, 1);
      expect(
        (await timed.confirm(preview, frame())).status,
        WebPanelBridgeStatus.unconfirmed,
      );
      expect(port.executes, 1);
    },
  );
  test('grant expires at the monotonic arm to preview boundary', () {
    var elapsed = Duration.zero;
    final port = Port();
    final controller = WebPanelNativeBridgeController(
      port: port,
      isCurrent: (candidate) => candidate == scope,
      grantIds: () => 'abcdef0123456789abcdef0123456789',
      previewIds: () => 'fedcba9876543210fedcba9876543210',
      elapsed: () => elapsed,
    );
    controller.arm(WebPanelNativeMethod.speak, scope);
    elapsed = const Duration(seconds: 30);
    expect(
      controller.preview(command(), frame()).status,
      WebPanelBridgeStatus.denied,
    );
    expect(port.executes, 0);
  });

  test('confirmation expires at the monotonic preview boundary', () async {
    var elapsed = Duration.zero;
    final port = Port();
    final controller = WebPanelNativeBridgeController(
      port: port,
      isCurrent: (candidate) => candidate == scope,
      grantIds: () => 'abcdef0123456789abcdef0123456789',
      previewIds: () => 'fedcba9876543210fedcba9876543210',
      elapsed: () => elapsed,
    );
    controller.arm(WebPanelNativeMethod.speak, scope);
    final preview = controller.preview(command(), frame());
    expect(preview.status, WebPanelBridgeStatus.needsConfirmation);
    elapsed = const Duration(seconds: 30);
    expect(
      (await controller.confirm(preview, frame())).status,
      WebPanelBridgeStatus.denied,
    );
    expect(port.executes, 0);
    expect(
      () => controller.arm(
        WebPanelNativeMethod.speak,
        scope,
        ttl: const Duration(seconds: 31),
      ),
      throwsFormatException,
    );
  });

  test('capability revision drift after dispatch is unconfirmed and never replayed', () async {
    final gate = Completer<void>();
    final port = Port(gate: gate);
    final controller = WebPanelNativeBridgeController(
      port: port,
      isCurrent: (candidate) => candidate == scope,
      grantIds: () => 'abcdef0123456789abcdef0123456789',
      previewIds: () => 'fedcba9876543210fedcba9876543210',
    );
    controller.arm(WebPanelNativeMethod.speak, scope);
    final preview = controller.preview(command(), frame());
    final pending = controller.confirm(preview, frame());
    port.revision++;
    gate.complete();
    expect((await pending).status, WebPanelBridgeStatus.unconfirmed);
    expect(
      (await controller.confirm(preview, frame())).status,
      WebPanelBridgeStatus.unconfirmed,
    );
    expect(port.executes, 1);
  });

  test(
    'verified Core consent retires pending confirmation exactly once',
    () async {
      var current = true;
      final authority = WebPanelNativeAuthorityLease.verifiedCore(
        coreId: '0123456789abcdef0123456789abcdef',
        homeId: 'abcdef0123456789abcdef0123456789',
        accountId: 'member@example',
        sessionFamily: '11111111111111111111111111111111',
        sourceId: 'panel-kitchen',
        sourceRevision: 3,
        isCurrent: () => current,
      );
      final policy = WebPanelNativePolicy(
        revision: 5,
        topOrigin: 'https://panel.example',
        methods: {WebPanelNativeMethod.speak},
      );
      final port = Port();
      final runtime = WebPanelNativeRuntime(
        policy: policy,
        authority: authority,
        port: port,
        routeEpoch: 7,
        lifecycleEpoch: 9,
        grantIds: () => 'abcdef0123456789abcdef0123456789',
        previewIds: () => 'fedcba9876543210fedcba9876543210',
      );
      final grant = runtime.arm(WebPanelNativeMethod.speak);
      expect(grant, 'abcdef0123456789abcdef0123456789');
      final pending = runtime.handle(
        WebPanelNativeMessage(
          message: command(grantId: grant!),
          topOrigin: 'https://panel.example',
          policyRevision: 5,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(runtime.status, WebPanelNativeRuntimeStatus.awaitingConfirmation);
      current = false;
      runtime.retire();
      final reply = jsonDecode(await pending) as Map<String, Object?>;
      expect(reply['status'], WebPanelBridgeStatus.denied.name);
      runtime.confirm();
      expect(port.executes, 0);
    },
  );

  test(
    'capability revision drift invalidates armed consent before dispatch',
    () async {
      final authority = WebPanelNativeAuthorityLease.verifiedCore(
        coreId: '0123456789abcdef0123456789abcdef',
        homeId: 'abcdef0123456789abcdef0123456789',
        accountId: 'member@example',
        sessionFamily: '11111111111111111111111111111111',
        sourceId: 'panel-kitchen',
        sourceRevision: 3,
        isCurrent: () => true,
      );
      final policy = WebPanelNativePolicy(
        revision: 5,
        topOrigin: 'https://panel.example',
        methods: {WebPanelNativeMethod.speak},
      );
      final port = Port();
      final runtime = WebPanelNativeRuntime(
        policy: policy,
        authority: authority,
        port: port,
        routeEpoch: 7,
        lifecycleEpoch: 9,
        grantIds: () => 'abcdef0123456789abcdef0123456789',
        previewIds: () => 'fedcba9876543210fedcba9876543210',
      );
      final grant = runtime.arm(WebPanelNativeMethod.speak)!;
      port.revision++;
      final reply = jsonDecode(
        await runtime.handle(
          WebPanelNativeMessage(
            message: command(grantId: grant),
            topOrigin: policy.topOrigin,
            policyRevision: policy.revision,
          ),
        ),
      ) as Map<String, Object?>;
      expect(reply['status'], WebPanelBridgeStatus.denied.name);
      expect(port.executes, 0);
      port.revision--;
      final replay = jsonDecode(
        await runtime.handle(
          WebPanelNativeMessage(
            message: command(grantId: grant),
            topOrigin: policy.topOrigin,
            policyRevision: policy.revision,
          ),
        ),
      ) as Map<String, Object?>;
      expect(replay['status'], WebPanelBridgeStatus.denied.name);
      expect(port.executes, 0);
    },
  );
}
