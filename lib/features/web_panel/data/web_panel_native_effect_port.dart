import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/web_panel_native_bridge.dart';
import 'web_panel_native_runtime.dart';

typedef WebPanelQrScan = Future<bool> Function(Set<String> formats);
typedef WebPanelQrCancel = Future<void> Function();

/// Android production adapter. It carries bounded command data and non-secret
/// authority revisions only; Core tokens, URLs, cookies and headers never
/// cross this channel.
final class AndroidWebPanelNativeEffectPort
    implements WebPanelNativeBridgePort, WebPanelNativeLifecyclePort {
  AndroidWebPanelNativeEffectPort({
    MethodChannel channel = const MethodChannel(channelName),
    String? ownerId,
    Set<WebPanelNativeMethod> capabilities = const {
      WebPanelNativeMethod.speak,
      WebPanelNativeMethod.printDocument,
      WebPanelNativeMethod.scanQr,
    },
    int capabilityRevision = 3,
    WebPanelQrScan? scanQr,
    WebPanelQrCancel? cancelQr,
  }) : // Public dependency seams intentionally avoid exposing private names.
       // ignore: prefer_initializing_formals
       _channel = channel,
       _ownerId = ownerId ?? secureWebPanelNativeId(),
       _capabilities = Set.unmodifiable(capabilities),
       // ignore: prefer_initializing_formals
       _capabilityRevision = capabilityRevision,
       // ignore: prefer_initializing_formals
       _scanQr = scanQr,
       // ignore: prefer_initializing_formals
       _cancelQr = cancelQr;

  static const channelName = 'com.ersingundem.larenor/web_panel_native_effects';
  final MethodChannel _channel;
  final String _ownerId;
  final Set<WebPanelNativeMethod> _capabilities;
  final int _capabilityRevision;
  final WebPanelQrScan? _scanQr;
  final WebPanelQrCancel? _cancelQr;
  final Set<String> _localReceipts = {};
  WebPanelBridgeScope? _bound;
  bool _retired = false;

  @override
  Set<WebPanelNativeMethod> get capabilities =>
      _retired ? const {} : _capabilities;
  @override
  int get capabilityRevision => _retired ? 0 : _capabilityRevision;

  @override
  Future<bool> bind(WebPanelBridgeScope scope) async {
    if (_retired || !scope.valid) return false;
    if (_bound == scope) return true;
    try {
      final accepted = await _channel
          .invokeMethod<bool>('bind', {
            'ownerId': _ownerId,
            'scope': _scope(scope),
          })
          .timeout(const Duration(seconds: 5));
      if (accepted == true && !_retired) {
        _bound = scope;
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<WebPanelNativePortResult> execute(
    WebPanelNativeCommand value,
    WebPanelBridgeTrustedFrame trusted,
  ) async {
    if (_retired || trusted.binding != _bound || !await bind(trusted.binding)) {
      return const WebPanelNativePortResult(
        outcome: WebPanelNativePortOutcome.rejected,
      );
    }
    if (value.method == WebPanelNativeMethod.scanQr) {
      return _executeQr(value);
    }
    try {
      final raw = await _channel
          .invokeMapMethod<String, Object?>('execute', {
            'ownerId': _ownerId,
            'operationId': value.requestId,
            'method': value.method.name,
            'payload': value.payload,
            'scope': _scope(trusted.binding),
          })
          .timeout(const Duration(seconds: 10));
      if (_retired || raw == null || raw['operationId'] != value.requestId) {
        return const WebPanelNativePortResult(
          outcome: WebPanelNativePortOutcome.uncertain,
        );
      }
      final outcome = switch (raw['outcome']) {
        'accepted' => WebPanelNativePortOutcome.accepted,
        'rejected' => WebPanelNativePortOutcome.rejected,
        'unsupported' => WebPanelNativePortOutcome.unsupported,
        _ => WebPanelNativePortOutcome.uncertain,
      };
      final handle = raw['receiptHandle'];
      return WebPanelNativePortResult(
        outcome: outcome,
        receiptHandle:
            outcome == WebPanelNativePortOutcome.accepted && handle is String
            ? handle
            : null,
      );
    } catch (_) {
      return const WebPanelNativePortResult(
        outcome: WebPanelNativePortOutcome.uncertain,
      );
    }
  }

  Future<WebPanelNativePortResult> _executeQr(
    WebPanelNativeCommand value,
  ) async {
    final scanner = _scanQr;
    final rawFormats = value.payload['formats'];
    final formats = rawFormats is List<Object?>
        ? rawFormats.whereType<String>().toSet()
        : const {'qr'};
    if (scanner == null || formats.length != 1 || !formats.contains('qr')) {
      return const WebPanelNativePortResult(
        outcome: WebPanelNativePortOutcome.unsupported,
      );
    }
    try {
      final accepted = await scanner(formats)
          .timeout(const Duration(seconds: 30));
      if (_retired) {
        return const WebPanelNativePortResult(
          outcome: WebPanelNativePortOutcome.uncertain,
        );
      }
      if (!accepted) {
        return const WebPanelNativePortResult(
          outcome: WebPanelNativePortOutcome.rejected,
        );
      }
      _localReceipts.add(value.requestId);
      return WebPanelNativePortResult(
        outcome: WebPanelNativePortOutcome.accepted,
        receiptHandle: value.requestId,
      );
    } catch (_) {
      return const WebPanelNativePortResult(
        outcome: WebPanelNativePortOutcome.uncertain,
      );
    }
  }

  @override
  Future<bool> readback(
    String receiptHandle,
    WebPanelNativeCommand value,
    WebPanelBridgeTrustedFrame trusted,
  ) async {
    if (_retired || trusted.binding != _bound) return false;
    if (value.method == WebPanelNativeMethod.scanQr) {
      return receiptHandle == value.requestId &&
          _localReceipts.remove(receiptHandle);
    }
    try {
      return await _channel
              .invokeMethod<bool>('readback', {
                'receiptHandle': receiptHandle,
                'operationId': value.requestId,
              })
              .timeout(const Duration(seconds: 5)) ==
          true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> retire(WebPanelBridgeScope scope) async {
    if (_retired || _bound != scope) return;
    _retired = true;
    _bound = null;
    _localReceipts.clear();
    try {
      await _cancelQr?.call().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await _channel
          .invokeMethod<void>('retire', {'ownerId': _ownerId})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Local retirement is terminal even when the platform is unavailable.
    }
  }

  static Map<String, Object?> _scope(WebPanelBridgeScope value) => {
    'coreId': value.coreId,
    'homeId': value.homeId,
    'accountId': value.accountId,
    'sessionFamily': value.sessionFamily,
    'sourceId': value.sourceId,
    'sourceRevision': value.sourceRevision,
    'policyRevision': value.policyRevision,
    'routeEpoch': value.routeEpoch,
    'lifecycleEpoch': value.lifecycleEpoch,
    'topOrigin': value.topOrigin,
  };
}
