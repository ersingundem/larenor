import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'web_panel_policy.dart';

const _maxBridgeMessageBytes = 8 * 1024;
const _maxLedgerEntries = 128;
final _opaqueId = RegExp(r'^[0-9a-f]{32}$');
final _scopeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
final _receiptHandle = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');

enum WebPanelNativeMethod { speak, printDocument, scanQr }

enum WebPanelBridgeStatus {
  denied,
  needsConfirmation,
  observed,
  unconfirmed,
  unsupported,
}

enum WebPanelNativePortOutcome { accepted, rejected, unsupported, uncertain }

@immutable
final class WebPanelBridgeScope {
  const WebPanelBridgeScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamily,
    required this.sourceId,
    required this.sourceRevision,
    required this.policyRevision,
    required this.routeEpoch,
    required this.lifecycleEpoch,
    required this.topOrigin,
  });

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionFamily;
  final String sourceId;
  final int sourceRevision;
  final int policyRevision;
  final int routeEpoch;
  final int lifecycleEpoch;
  final String topOrigin;

  bool get valid =>
      _scopeId.hasMatch(coreId) &&
      _scopeId.hasMatch(homeId) &&
      _scopeId.hasMatch(accountId) &&
      _scopeId.hasMatch(sessionFamily) &&
      _scopeId.hasMatch(sourceId) &&
      sourceRevision > 0 &&
      policyRevision > 0 &&
      routeEpoch > 0 &&
      lifecycleEpoch > 0 &&
      _isSecureOrigin(topOrigin);

  @override
  bool operator ==(Object other) =>
      other is WebPanelBridgeScope &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId &&
      sessionFamily == other.sessionFamily &&
      sourceId == other.sourceId &&
      sourceRevision == other.sourceRevision &&
      policyRevision == other.policyRevision &&
      routeEpoch == other.routeEpoch &&
      lifecycleEpoch == other.lifecycleEpoch &&
      topOrigin == other.topOrigin;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionFamily,
    sourceId,
    sourceRevision,
    policyRevision,
    routeEpoch,
    lifecycleEpoch,
    topOrigin,
  );
}

@immutable
final class WebPanelBridgeTrustedFrame {
  const WebPanelBridgeTrustedFrame({
    required this.binding,
    required this.topOrigin,
    required this.mainFrame,
    required this.newWindow,
    required this.foreground,
    required this.routeVisible,
  });

  final WebPanelBridgeScope binding;

  /// Populated by a native frame-aware adapter. Page-supplied origin text is
  /// never authoritative.
  final String topOrigin;
  final bool mainFrame;
  final bool newWindow;
  final bool foreground;
  final bool routeVisible;
}

@immutable
final class WebPanelNativeCommand {
  WebPanelNativeCommand._({
    required this.sequence,
    required this.requestId,
    required this.grantId,
    required this.method,
    required Map<String, Object?> payload,
  }) : payload = Map.unmodifiable(payload);

  final int sequence;
  final String requestId;
  final String grantId;
  final WebPanelNativeMethod method;
  final Map<String, Object?> payload;

  static WebPanelNativeCommand parse(String raw) {
    if (utf8.encode(raw).length > _maxBridgeMessageBytes) {
      throw const FormatException('bridge_message_invalid');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('bridge_message_invalid');
    }
    if (decoded is! Map<String, Object?> ||
        !_exactKeys(decoded, const {
          'schemaVersion',
          'sequence',
          'requestId',
          'grantId',
          'method',
          'payload',
        }) ||
        decoded['schemaVersion'] != 1) {
      throw const FormatException('bridge_message_invalid');
    }
    final sequence = decoded['sequence'];
    final requestId = decoded['requestId'];
    final grantId = decoded['grantId'];
    final methodName = decoded['method'];
    final rawPayload = decoded['payload'];
    if (sequence is! int ||
        sequence < 1 ||
        sequence > 0x7fffffff ||
        requestId is! String ||
        !_opaqueId.hasMatch(requestId) ||
        grantId is! String ||
        !_opaqueId.hasMatch(grantId) ||
        methodName is! String ||
        rawPayload is! Map<String, Object?>) {
      throw const FormatException('bridge_message_invalid');
    }
    final method = switch (methodName) {
      'speak' => WebPanelNativeMethod.speak,
      'printDocument' => WebPanelNativeMethod.printDocument,
      'scanQr' => WebPanelNativeMethod.scanQr,
      _ => throw const FormatException('bridge_method_unsupported'),
    };
    final payload = Map<String, Object?>.from(rawPayload);
    _validatePayload(method, payload);
    return WebPanelNativeCommand._(
      sequence: sequence,
      requestId: requestId,
      grantId: grantId,
      method: method,
      payload: payload,
    );
  }

  static void _validatePayload(
    WebPanelNativeMethod method,
    Map<String, Object?> payload,
  ) {
    switch (method) {
      case WebPanelNativeMethod.speak:
        if (!_exactKeys(
              payload,
              const {'text', 'locale'},
              optional: const {'locale'},
            ) ||
            !_safeText(payload['text'], 500)) {
          throw const FormatException('bridge_payload_invalid');
        }
        final locale = payload['locale'];
        if (locale != null &&
            (locale is! String ||
                !RegExp(r'^[a-z]{2,3}(?:-[A-Z]{2})?$').hasMatch(locale))) {
          throw const FormatException('bridge_payload_invalid');
        }
      case WebPanelNativeMethod.printDocument:
        if (!_exactKeys(
              payload,
              const {'documentHandle', 'title'},
              optional: const {'title'},
            ) ||
            payload['documentHandle'] is! String ||
            !_receiptHandle.hasMatch(payload['documentHandle']! as String)) {
          throw const FormatException('bridge_payload_invalid');
        }
        final title = payload['title'];
        if (title != null && !_safeText(title, 120)) {
          throw const FormatException('bridge_payload_invalid');
        }
      case WebPanelNativeMethod.scanQr:
        if (!_exactKeys(
          payload,
          const {'formats'},
          optional: const {'formats'},
        )) {
          throw const FormatException('bridge_payload_invalid');
        }
        final formats = payload['formats'];
        if (formats != null &&
            (formats is! List<Object?> ||
                formats.isEmpty ||
                formats.length > 2 ||
                formats.any(
                  (value) => !const {'qr', 'dataMatrix'}.contains(value),
                ))) {
          throw const FormatException('bridge_payload_invalid');
        }
    }
  }
}

@immutable
final class WebPanelNativePortResult {
  const WebPanelNativePortResult({required this.outcome, this.receiptHandle});

  final WebPanelNativePortOutcome outcome;
  final String? receiptHandle;

  bool get valid => switch (outcome) {
    WebPanelNativePortOutcome.accepted =>
      receiptHandle != null && _receiptHandle.hasMatch(receiptHandle!),
    _ => receiptHandle == null,
  };
}

abstract interface class WebPanelNativeBridgePort {
  Set<WebPanelNativeMethod> get capabilities;

  Future<WebPanelNativePortResult> execute(
    WebPanelNativeCommand value,
    WebPanelBridgeTrustedFrame trusted,
  );

  Future<bool> readback(
    String receiptHandle,
    WebPanelNativeCommand value,
    WebPanelBridgeTrustedFrame trusted,
  );
}

/// Safe production default while no frame-aware Android adapter is installed.
final class UnsupportedWebPanelNativeBridgePort
    implements WebPanelNativeBridgePort {
  const UnsupportedWebPanelNativeBridgePort();

  @override
  Set<WebPanelNativeMethod> get capabilities => const {};

  @override
  Future<WebPanelNativePortResult> execute(
    WebPanelNativeCommand value,
    WebPanelBridgeTrustedFrame trusted,
  ) async => const WebPanelNativePortResult(
    outcome: WebPanelNativePortOutcome.unsupported,
  );

  @override
  Future<bool> readback(
    String receiptHandle,
    WebPanelNativeCommand value,
    WebPanelBridgeTrustedFrame trusted,
  ) async => false;
}

@immutable
final class WebPanelBridgePreview {
  const WebPanelBridgePreview._({
    required this.status,
    this.previewId,
    this.requestId,
    this.method,
    this._controllerEpoch,
  });

  const WebPanelBridgePreview.denied()
    : status = WebPanelBridgeStatus.denied,
      previewId = null,
      requestId = null,
      method = null,
      _controllerEpoch = null;

  final WebPanelBridgeStatus status;
  final String? previewId;
  final String? requestId;
  final WebPanelNativeMethod? method;
  final int? _controllerEpoch;
}

@immutable
final class WebPanelBridgeReceipt {
  const WebPanelBridgeReceipt({
    required this.requestId,
    required this.sequence,
    required this.method,
    required this.status,
    required this.reasonCode,
  });

  final String requestId;
  final int sequence;
  final WebPanelNativeMethod method;
  final WebPanelBridgeStatus status;
  final String reasonCode;

  Map<String, Object?> toPublicJson() => {
    'schemaVersion': 1,
    'requestId': requestId,
    'sequence': sequence,
    'method': method.name,
    'status': status.name,
    'reasonCode': reasonCode,
  };
}

typedef WebPanelBridgeIdFactory = String Function();

final class WebPanelNativeBridgeController {
  WebPanelNativeBridgeController({
    required this.port,
    required this.isCurrent,
    required this._grantIds,
    required this._previewIds,
    DateTime Function()? now,
    Duration portTimeout = const Duration(seconds: 10),
  }) : _now = now ?? DateTime.now,
       _portTimeout = portTimeout {
    if (portTimeout <= Duration.zero ||
        portTimeout > const Duration(seconds: 30)) {
      throw ArgumentError.value(portTimeout, 'portTimeout');
    }
  }

  final WebPanelNativeBridgePort port;
  final bool Function(WebPanelBridgeScope) isCurrent;
  final WebPanelBridgeIdFactory _grantIds, _previewIds;
  final DateTime Function() _now;
  final Duration _portTimeout;
  final Map<String, _RequestRecord> _ledger = {};
  _Grant? _grant;
  int _nextSequence = 1, _controllerEpoch = 0;

  String arm(
    WebPanelNativeMethod method,
    WebPanelBridgeScope binding, {
    Duration ttl = const Duration(seconds: 30),
  }) {
    if (!binding.valid ||
        ttl <= Duration.zero ||
        ttl > const Duration(minutes: 2)) {
      throw const FormatException('bridge_grant_invalid');
    }
    final id = _grantIds();
    if (!_opaqueId.hasMatch(id)) {
      throw const FormatException('bridge_grant_invalid');
    }
    _controllerEpoch++;
    _grant = _Grant(
      id: id,
      method: method,
      binding: binding,
      expiresAt: _now().add(ttl),
      controllerEpoch: _controllerEpoch,
    );
    return id;
  }

  void revoke() {
    _controllerEpoch++;
    _grant = null;
  }

  WebPanelBridgePreview preview(
    String raw,
    WebPanelBridgeTrustedFrame trusted,
  ) {
    final WebPanelNativeCommand value;
    try {
      value = WebPanelNativeCommand.parse(raw);
    } on FormatException {
      return const WebPanelBridgePreview.denied();
    }
    final grant = _grant;
    if (grant == null ||
        grant.used ||
        grant.controllerEpoch != _controllerEpoch ||
        grant.id != value.grantId ||
        grant.method != value.method ||
        value.sequence != _nextSequence ||
        _ledger.containsKey(value.requestId) ||
        !_trusted(trusted, grant.binding) ||
        !grant.expiresAt.isAfter(_now())) {
      return const WebPanelBridgePreview.denied();
    }
    grant.used = true;
    _grant = null;
    _nextSequence++;
    final previewId = _previewIds();
    if (!_opaqueId.hasMatch(previewId)) {
      return const WebPanelBridgePreview.denied();
    }
    final supported = port.capabilities.contains(value.method);
    final preview = WebPanelBridgePreview._(
      status: supported
          ? WebPanelBridgeStatus.needsConfirmation
          : WebPanelBridgeStatus.unsupported,
      previewId: previewId,
      requestId: value.requestId,
      method: value.method,
      controllerEpoch: _controllerEpoch,
    );
    _ledger[value.requestId] = _RequestRecord(
      value: value,
      previewId: previewId,
      binding: grant.binding,
      controllerEpoch: _controllerEpoch,
      expiresAt: grant.expiresAt,
      unsupported: !supported,
    );
    while (_ledger.length > _maxLedgerEntries) {
      _ledger.remove(_ledger.keys.first);
    }
    return preview;
  }

  Future<WebPanelBridgeReceipt> confirm(
    WebPanelBridgePreview preview,
    WebPanelBridgeTrustedFrame trusted,
  ) async {
    final requestId = preview.requestId;
    final record = requestId == null ? null : _ledger[requestId];
    if (record == null ||
        preview.status != WebPanelBridgeStatus.needsConfirmation ||
        preview.previewId != record.previewId ||
        preview._controllerEpoch != record.controllerEpoch ||
        record.controllerEpoch != _controllerEpoch ||
        !_trusted(trusted, record.binding)) {
      return _denied(record?.value);
    }
    if (record.receipt != null) return record.receipt!;
    if (!record.expiresAt.isAfter(_now())) {
      return record.receipt = _receipt(
        record.value,
        WebPanelBridgeStatus.denied,
        'grant_expired',
      );
    }
    if (record.unsupported) {
      return record.receipt = _receipt(
        record.value,
        WebPanelBridgeStatus.unsupported,
        'capability_unavailable',
      );
    }
    if (record.dispatching) {
      return _receipt(
        record.value,
        WebPanelBridgeStatus.unconfirmed,
        'dispatch_in_progress',
      );
    }
    record.dispatching = true;
    try {
      final result = await port
          .execute(record.value, trusted)
          .timeout(_portTimeout);
      if (record.controllerEpoch != _controllerEpoch ||
          !_trusted(trusted, record.binding) ||
          !result.valid) {
        return record.receipt = _receipt(
          record.value,
          WebPanelBridgeStatus.unconfirmed,
          'effect_unconfirmed',
        );
      }
      switch (result.outcome) {
        case WebPanelNativePortOutcome.rejected:
          return record.receipt = _receipt(
            record.value,
            WebPanelBridgeStatus.denied,
            'native_rejected',
          );
        case WebPanelNativePortOutcome.unsupported:
          return record.receipt = _receipt(
            record.value,
            WebPanelBridgeStatus.unsupported,
            'capability_unavailable',
          );
        case WebPanelNativePortOutcome.uncertain:
          return record.receipt = _receipt(
            record.value,
            WebPanelBridgeStatus.unconfirmed,
            'effect_unconfirmed',
          );
        case WebPanelNativePortOutcome.accepted:
          final observed = await port
              .readback(result.receiptHandle!, record.value, trusted)
              .timeout(_portTimeout);
          if (record.controllerEpoch != _controllerEpoch ||
              !_trusted(trusted, record.binding)) {
            return record.receipt = _receipt(
              record.value,
              WebPanelBridgeStatus.unconfirmed,
              'effect_unconfirmed',
            );
          }
          return record.receipt = _receipt(
            record.value,
            observed
                ? WebPanelBridgeStatus.observed
                : WebPanelBridgeStatus.unconfirmed,
            observed ? 'effect_observed' : 'effect_unconfirmed',
          );
      }
    } catch (_) {
      return record.receipt = _receipt(
        record.value,
        WebPanelBridgeStatus.unconfirmed,
        'effect_unconfirmed',
      );
    }
  }

  bool _trusted(
    WebPanelBridgeTrustedFrame trusted,
    WebPanelBridgeScope expected,
  ) {
    if (!expected.valid ||
        trusted.binding != expected ||
        trusted.topOrigin != expected.topOrigin ||
        !trusted.mainFrame ||
        trusted.newWindow ||
        !trusted.foreground ||
        !trusted.routeVisible ||
        !_isSecureOrigin(trusted.topOrigin)) {
      return false;
    }
    try {
      return isCurrent(expected);
    } catch (_) {
      return false;
    }
  }

  static WebPanelBridgeReceipt _denied(WebPanelNativeCommand? value) =>
      WebPanelBridgeReceipt(
        requestId: value?.requestId ?? '00000000000000000000000000000000',
        sequence: value?.sequence ?? 0,
        method: value?.method ?? WebPanelNativeMethod.speak,
        status: WebPanelBridgeStatus.denied,
        reasonCode: 'authority_denied',
      );

  static WebPanelBridgeReceipt _receipt(
    WebPanelNativeCommand value,
    WebPanelBridgeStatus status,
    String reason,
  ) => WebPanelBridgeReceipt(
    requestId: value.requestId,
    sequence: value.sequence,
    method: value.method,
    status: status,
    reasonCode: reason,
  );
}

final class _Grant {
  _Grant({
    required this.id,
    required this.method,
    required this.binding,
    required this.expiresAt,
    required this.controllerEpoch,
  });

  final String id;
  final WebPanelNativeMethod method;
  final WebPanelBridgeScope binding;
  final DateTime expiresAt;
  final int controllerEpoch;
  bool used = false;
}

final class _RequestRecord {
  _RequestRecord({
    required this.value,
    required this.previewId,
    required this.binding,
    required this.controllerEpoch,
    required this.expiresAt,
    required this.unsupported,
  });

  final WebPanelNativeCommand value;
  final String previewId;
  final WebPanelBridgeScope binding;
  final int controllerEpoch;
  final DateTime expiresAt;
  final bool unsupported;
  bool dispatching = false;
  WebPanelBridgeReceipt? receipt;
}

bool _exactKeys(
  Map<String, Object?> value,
  Set<String> allowed, {
  Set<String> optional = const {},
}) =>
    value.keys.every(allowed.contains) &&
    allowed.difference(optional).every(value.containsKey);

bool _safeText(Object? value, int maxLength) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= maxLength &&
    !RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value);

bool _isSecureOrigin(String value) {
  final origin = WebOrigin.parse(value);
  if (origin == null || origin.scheme != 'https') return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.userInfo.isEmpty &&
      (uri.path.isEmpty || uri.path == '/') &&
      !uri.hasQuery &&
      !uri.hasFragment;
}
