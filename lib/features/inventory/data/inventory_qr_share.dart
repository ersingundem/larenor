import 'package:flutter/services.dart';

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
final class InventoryQrShare {
  InventoryQrShare({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.ersingundem.larenor/inventory_share';
  static final _sessionPattern = RegExp(r'^[A-Za-z0-9._-]{8,128}$');
  final MethodChannel _channel;

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
