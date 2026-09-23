import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/inventory_models.dart';
import '../domain/inventory_qr_export.dart';

final class InventoryShareSnapshot {
  const InventoryShareSnapshot({
    required this.supported,
    required this.resumed,
    required this.focused,
    required this.interactionEpoch,
  });

  factory InventoryShareSnapshot.fromPlatform(Object? raw) {
    if (raw is! Map ||
        raw.length != 4 ||
        !const {
          'supported',
          'resumed',
          'focused',
          'interactionEpoch',
        }.every(raw.containsKey)) {
      throw const FormatException('Invalid inventory share snapshot.');
    }
    final supported = raw['supported'];
    final resumed = raw['resumed'];
    final focused = raw['focused'];
    final epoch = raw['interactionEpoch'];
    if (supported is! bool ||
        resumed is! bool ||
        focused is! bool ||
        epoch is! int ||
        epoch < 0) {
      throw const FormatException('Invalid inventory share snapshot.');
    }
    return InventoryShareSnapshot(
      supported: supported,
      resumed: resumed,
      focused: focused,
      interactionEpoch: epoch,
    );
  }

  final bool supported;
  final bool resumed;
  final bool focused;
  final int interactionEpoch;
}

/// Explicit Android share-sheet bridge for canonical inventory SVG files.
/// The native side owns lifecycle/focus authority and private file exposure.
abstract interface class InventoryQrShareGateway {
  Future<InventoryShareSnapshot> activate(String sessionId);
  Future<void> share({
    required InventoryQrExport export,
    required String sessionId,
    required int interactionEpoch,
  });
}

final class InventoryQrShare implements InventoryQrShareGateway {
  InventoryQrShare({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.ersingundem.larenor/inventory_share';
  static final _sessionPattern = RegExp(r'^[A-Za-z0-9._-]{8,128}$');
  final MethodChannel _channel;

  @override
  Future<InventoryShareSnapshot> activate(String sessionId) {
    _validateSession(sessionId);
    return _activate(sessionId);
  }

  Future<InventoryShareSnapshot> _activate(String sessionId) async {
    await _channel.invokeMethod<void>('activateSession', {
      'sessionId': sessionId,
    });
    return InventoryShareSnapshot.fromPlatform(
      await _channel.invokeMethod<Object?>('snapshot'),
    );
  }

  @override
  Future<void> share({
    required InventoryQrExport export,
    required String sessionId,
    required int interactionEpoch,
  }) {
    _validateSession(sessionId);
    if (interactionEpoch < 0) {
      throw ArgumentError.value(interactionEpoch, 'interactionEpoch');
    }
    if (!RegExp(r'^larenor-inventory-[0-9a-f]{32}\.svg$')
            .hasMatch(export.fileName) ||
        export.mimeType != 'image/svg+xml' ||
        export.svg.isEmpty ||
        export.svg.length > 256000) {
      throw ArgumentError.value(export, 'export');
    }
    return _channel.invokeMethod<void>('shareSvg', {
      'sessionId': sessionId,
      'interactionEpoch': interactionEpoch,
      'fileName': export.fileName,
      'mimeType': export.mimeType,
      'svg': export.svg,
    });
  }

  static void _validateSession(String value) {
    if (!_sessionPattern.hasMatch(value)) {
      throw ArgumentError.value(value, 'sessionId');
    }
  }
}

enum InventoryLabelShareFailure { unavailable, stale }

/// Owns one explicit label-export effect for the current account/home route.
/// Every tap gets a fresh native epoch; a route change retires the result.
final class InventoryLabelShareController extends ChangeNotifier {
  factory InventoryLabelShareController({
    required InventoryQrShareGateway gateway,
    required String sessionId,
    required bool Function() isCurrent,
  }) {
    InventoryQrShare._validateSession(sessionId);
    return InventoryLabelShareController._(gateway, sessionId, isCurrent);
  }

  InventoryLabelShareController._(
    this._gateway,
    this._sessionId,
    this._isCurrent,
  );

  final InventoryQrShareGateway _gateway;
  final String _sessionId;
  final bool Function() _isCurrent;
  int _operation = 0;
  bool _retired = false;
  bool busy = false;
  InventoryLabelShareFailure? failure;

  bool _current(int operation) {
    try {
      return !_retired && operation == _operation && _isCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<void> share(InventoryItem item) async {
    if (busy || _retired) return;
    final operation = ++_operation;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      if (!_current(operation)) throw const _StaleInventoryShare();
      final export = InventoryQrExport.fromQr(InventoryQr.forItem(item));
      final snapshot = await _gateway.activate(_sessionId);
      if (!_current(operation) ||
          !snapshot.supported ||
          !snapshot.resumed ||
          !snapshot.focused) {
        throw const _StaleInventoryShare();
      }
      await _gateway.share(
        export: export,
        sessionId: _sessionId,
        interactionEpoch: snapshot.interactionEpoch,
      );
      if (!_current(operation)) throw const _StaleInventoryShare();
    } on _StaleInventoryShare {
      if (!_retired && operation == _operation) {
        failure = InventoryLabelShareFailure.stale;
      }
    } catch (_) {
      if (!_retired && operation == _operation) {
        failure = _current(operation)
            ? InventoryLabelShareFailure.unavailable
            : InventoryLabelShareFailure.stale;
      }
    } finally {
      if (!_retired && operation == _operation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _operation++;
    busy = false;
    failure = InventoryLabelShareFailure.stale;
    notifyListeners();
  }
}

final class _StaleInventoryShare implements Exception {
  const _StaleInventoryShare();
}
