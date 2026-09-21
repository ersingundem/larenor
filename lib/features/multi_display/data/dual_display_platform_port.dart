import 'package:flutter/services.dart';

import '../domain/dual_display_session.dart';

const _defaultChannel = MethodChannel('com.ersingundem.larenor/dual_display');

abstract interface class DualDisplayPlatformPort
    implements SecondaryDisplayPort {
  Future<DisplayTopology> snapshot();
}

final class MethodChannelSecondaryDisplayPort
    implements DualDisplayPlatformPort {
  const MethodChannelSecondaryDisplayPort({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  final MethodChannel _channel;

  @override
  Future<DisplayTopology> snapshot() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('snapshot');
      final value = _closedMap(raw, const {'revision', 'surfaces'});
      final rawSurfaces = value['surfaces'];
      if (rawSurfaces is! List<Object?>) {
        throw const DualDisplayException('malformed_platform_response');
      }
      return DisplayTopology(
        revision: _integer(value['revision']),
        surfaces: rawSurfaces.map(_surface).toList(growable: false),
      );
    } on DualDisplayException {
      rethrow;
    } on Object {
      throw const DualDisplayException('platform_unavailable');
    }
  }

  @override
  Future<SecondaryPresentationReceipt> present(
    SecondaryPresentationRequest request,
  ) async {
    final arguments = <String, Object>{
      'sessionId': request.sessionId,
      'topologyRevision': request.topologyRevision,
      'displayId': request.display.displayId,
      'displayGeneration': request.display.generation,
      'routeId': request.routeId,
    };
    try {
      final raw = await _channel.invokeMethod<Object?>('present', arguments);
      final value = _closedMap(raw, const {
        'sessionId',
        'topologyRevision',
        'displayId',
        'displayGeneration',
        'routeId',
        'attached',
      });
      final receipt = SecondaryPresentationReceipt(
        sessionId: _text(value['sessionId']),
        displayId: _integer(value['displayId']),
        displayGeneration: _integer(value['displayGeneration']),
        topologyRevision: _integer(value['topologyRevision']),
        routeId: _text(value['routeId']),
        attached: _boolean(value['attached']),
      );
      if (receipt.sessionId != request.sessionId ||
          receipt.displayId != request.display.displayId ||
          receipt.displayGeneration != request.display.generation ||
          receipt.topologyRevision != request.topologyRevision ||
          receipt.routeId != request.routeId) {
        throw const DualDisplayException('malformed_platform_response');
      }
      return receipt;
    } on DualDisplayException {
      rethrow;
    } on Object {
      throw const DualDisplayException('platform_unavailable');
    }
  }

  @override
  Future<void> dismiss(SecondaryDismissal dismissal) async {
    try {
      await _channel.invokeMethod<void>('dismiss', {
        'sessionId': dismissal.sessionId,
        'displayId': dismissal.displayId,
      });
    } on Object {
      throw const DualDisplayException('platform_unavailable');
    }
  }

  static DisplaySurface _surface(Object? raw) {
    final value = _closedMap(raw, const {
      'displayId',
      'generation',
      'kind',
      'widthPixels',
      'heightPixels',
      'densityDpi',
      'securePresentation',
    });
    final kind = switch (_text(value['kind'])) {
      'primary' => DisplayKind.primary,
      'external' => DisplayKind.external,
      _ => throw const DualDisplayException('malformed_platform_response'),
    };
    return DisplaySurface(
      displayId: _integer(value['displayId']),
      generation: _integer(value['generation']),
      kind: kind,
      widthPixels: _integer(value['widthPixels']),
      heightPixels: _integer(value['heightPixels']),
      densityDpi: _integer(value['densityDpi']),
      securePresentation: _boolean(value['securePresentation']),
    );
  }

  static Map<Object?, Object?> _closedMap(Object? raw, Set<String> keys) {
    if (raw is! Map<Object?, Object?> ||
        raw.length != keys.length ||
        raw.keys.any((key) => key is! String || !keys.contains(key))) {
      throw const DualDisplayException('malformed_platform_response');
    }
    return raw;
  }

  static int _integer(Object? value) {
    if (value is! int) {
      throw const DualDisplayException('malformed_platform_response');
    }
    return value;
  }

  static String _text(Object? value) {
    if (value is! String) {
      throw const DualDisplayException('malformed_platform_response');
    }
    return value;
  }

  static bool _boolean(Object? value) {
    if (value is! bool) {
      throw const DualDisplayException('malformed_platform_response');
    }
    return value;
  }
}
