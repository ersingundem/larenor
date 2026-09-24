import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/web_panel_native_bridge.dart';
import 'web_panel_renderer_monitor.dart';

final _verifiedId = RegExp(r'^[0-9a-f]{32}$');
final _sourceId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');

@immutable
final class WebPanelNativeAuthorityLease {
  const WebPanelNativeAuthorityLease._({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamily,
    required this.sourceId,
    required this.sourceRevision,
    required this.currentCheck,
  });

  factory WebPanelNativeAuthorityLease.verifiedCore({
    required String coreId,
    required String homeId,
    required String accountId,
    required String sessionFamily,
    required String sourceId,
    required int sourceRevision,
    required bool Function() isCurrent,
  }) {
    if (!_verifiedId.hasMatch(coreId) ||
        !_verifiedId.hasMatch(homeId) ||
        !_verifiedId.hasMatch(sessionFamily) ||
        accountId.isEmpty ||
        accountId.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(accountId) ||
        !_sourceId.hasMatch(sourceId) ||
        sourceRevision < 1) {
      throw const FormatException('web_panel_authority_invalid');
    }
    return WebPanelNativeAuthorityLease._(
      coreId: coreId,
      homeId: homeId,
      accountId: accountId,
      sessionFamily: sessionFamily,
      sourceId: sourceId,
      sourceRevision: sourceRevision,
      currentCheck: isCurrent,
    );
  }

  final String coreId, homeId, accountId, sessionFamily, sourceId;
  final int sourceRevision;
  final bool Function() currentCheck;

  WebPanelBridgeScope bind(
    WebPanelNativePolicy policy, {
    required int routeEpoch,
    required int lifecycleEpoch,
  }) => WebPanelBridgeScope(
    coreId: coreId,
    homeId: homeId,
    accountId: accountId,
    sessionFamily: sessionFamily,
    sourceId: sourceId,
    sourceRevision: sourceRevision,
    policyRevision: policy.revision,
    routeEpoch: routeEpoch,
    lifecycleEpoch: lifecycleEpoch,
    topOrigin: policy.topOrigin,
  );

  bool current(WebPanelBridgeScope candidate, WebPanelBridgeScope captured) {
    if (candidate != captured) return false;
    try {
      return currentCheck();
    } catch (_) {
      return false;
    }
  }
}

enum WebPanelNativeRuntimeStatus { idle, armed, awaitingConfirmation, working }

final class WebPanelNativeRuntime extends ChangeNotifier {
  WebPanelNativeRuntime({
    required this.policy,
    required this.authority,
    required WebPanelNativeBridgePort port,
    required int routeEpoch,
    required int lifecycleEpoch,
    required WebPanelBridgeIdFactory grantIds,
    required WebPanelBridgeIdFactory previewIds,
    WebPanelBridgeElapsedClock? elapsed,
  }) : _scope = authority.bind(
         policy,
         routeEpoch: routeEpoch,
         lifecycleEpoch: lifecycleEpoch,
       ),
       _controller = WebPanelNativeBridgeController(
         port: port,
         isCurrent: (candidate) => authority.current(
           candidate,
           authority.bind(
             policy,
             routeEpoch: routeEpoch,
             lifecycleEpoch: lifecycleEpoch,
           ),
         ),
         grantIds: grantIds,
         previewIds: previewIds,
         elapsed: elapsed,
       ),
       _port = port;

  final WebPanelNativePolicy policy;
  final WebPanelNativeAuthorityLease authority;
  final WebPanelBridgeScope _scope;
  final WebPanelNativeBridgeController _controller;
  final WebPanelNativeBridgePort _port;
  WebPanelNativeRuntimeStatus _status = WebPanelNativeRuntimeStatus.idle;
  WebPanelNativeRuntimeStatus get status => _status;
  Set<WebPanelNativeMethod> get availableMethods {
    try {
      if (_port.capabilityRevision < 1) return const {};
      return Set.unmodifiable(policy.methods.intersection(_port.capabilities));
    } catch (_) {
      return const {};
    }
  }

  Completer<bool>? _decision;
  Timer? _decisionTimer;
  bool _retired = false;
  bool _notifierDisposed = false;
  int? _armedCapabilityRevision;

  String? arm(WebPanelNativeMethod method) {
    final int revision;
    final bool supported;
    try {
      revision = _port.capabilityRevision;
      supported = _port.capabilities.contains(method);
    } catch (_) {
      return null;
    }
    if (_retired ||
        !policy.methods.contains(method) ||
        !supported ||
        revision < 1 ||
        !authority.current(_scope, _scope)) {
      return null;
    }
    final grant = _controller.arm(method, _scope);
    _armedCapabilityRevision = revision;
    _status = WebPanelNativeRuntimeStatus.armed;
    _notify();
    return grant;
  }

  Future<String> handle(WebPanelNativeMessage message) async {
    final int currentCapabilityRevision;
    try {
      currentCapabilityRevision = _port.capabilityRevision;
    } catch (_) {
      return _staticReply(WebPanelBridgeStatus.denied, 'authority_denied');
    }
    if (_armedCapabilityRevision != null &&
        _armedCapabilityRevision != currentCapabilityRevision) {
      _controller.revoke();
      _armedCapabilityRevision = null;
      _status = WebPanelNativeRuntimeStatus.idle;
      _notify();
      return _staticReply(WebPanelBridgeStatus.denied, 'authority_denied');
    }
    if (_retired ||
        _decision != null ||
        _armedCapabilityRevision == null ||
        message.policyRevision != policy.revision ||
        message.topOrigin != policy.topOrigin ||
        !authority.current(_scope, _scope)) {
      return _staticReply(WebPanelBridgeStatus.denied, 'authority_denied');
    }
    _armedCapabilityRevision = null;
    final trusted = WebPanelBridgeTrustedFrame(
      binding: _scope,
      topOrigin: message.topOrigin,
      mainFrame: true,
      newWindow: false,
      foreground: true,
      routeVisible: true,
    );
    final preview = _controller.preview(message.message, trusted);
    if (preview.status != WebPanelBridgeStatus.needsConfirmation) {
      _status = WebPanelNativeRuntimeStatus.idle;
      _notify();
      return _staticReply(
        preview.status,
        preview.status == WebPanelBridgeStatus.unsupported
            ? 'capability_unavailable'
            : 'authority_denied',
      );
    }
    final decision = _decision = Completer<bool>();
    _status = WebPanelNativeRuntimeStatus.awaitingConfirmation;
    _notify();
    _decisionTimer = Timer(const Duration(seconds: 30), () {
      if (!decision.isCompleted) decision.complete(false);
    });
    final approved = await decision.future;
    _decisionTimer?.cancel();
    _decisionTimer = null;
    if (identical(_decision, decision)) _decision = null;
    if (_retired || !approved || !authority.current(_scope, _scope)) {
      _status = WebPanelNativeRuntimeStatus.idle;
      _notify();
      return _staticReply(WebPanelBridgeStatus.denied, 'authority_denied');
    }
    _status = WebPanelNativeRuntimeStatus.working;
    _notify();
    final receipt = await _controller.confirm(preview, trusted);
    _status = WebPanelNativeRuntimeStatus.idle;
    _notify();
    return jsonEncode(receipt.toPublicJson());
  }

  void confirm() {
    final decision = _decision;
    if (!_retired && decision != null && !decision.isCompleted) {
      decision.complete(true);
    }
  }

  void cancel() {
    final decision = _decision;
    if (decision != null && !decision.isCompleted) decision.complete(false);
  }

  void revokeConsent() {
    _controller.revoke();
    _armedCapabilityRevision = null;
    cancel();
    _status = WebPanelNativeRuntimeStatus.idle;
    _notify();
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _controller.revoke();
    _armedCapabilityRevision = null;
    _decisionTimer?.cancel();
    _decisionTimer = null;
    cancel();
    _status = WebPanelNativeRuntimeStatus.idle;
    _notify();
  }

  @override
  void dispose() {
    retire();
    _notifierDisposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_notifierDisposed) notifyListeners();
  }

  static String _staticReply(WebPanelBridgeStatus status, String reason) =>
      jsonEncode({
        'schemaVersion': 1,
        'status': status.name,
        'reasonCode': reason,
      });
}

String secureWebPanelNativeId() {
  final random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}
