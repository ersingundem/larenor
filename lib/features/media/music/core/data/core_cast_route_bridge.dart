import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class CoreCastRouteException implements Exception {
  const CoreCastRouteException(this.code);
  final String code;

  @override
  String toString() => 'CoreCastRouteException($code)';
}

enum CoreCastRouteKind { device, group }

enum CoreCastConnectionState { disconnected, connecting, connected, suspended }

class CoreCastRoute {
  const CoreCastRoute({
    required this.id,
    required this.name,
    required this.kind,
    required this.available,
    required this.connectionState,
    required this.volumeLevel,
  });

  factory CoreCastRoute.fromChannel(Object? value) {
    const keys = {
      'id',
      'name',
      'kind',
      'available',
      'connectionState',
      'volumeLevel',
    };
    if (value is! Map<Object?, Object?> ||
        value.length != keys.length ||
        !value.keys.every(keys.contains)) {
      throw const CoreCastRouteException('invalid_response');
    }
    final id = value['id'];
    final name = value['name'];
    final rawKind = value['kind'];
    final available = value['available'];
    final rawState = value['connectionState'];
    final volume = value['volumeLevel'];
    if (id is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(id) ||
        name is! String ||
        name.isEmpty ||
        name.length > 160 ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        rawKind is! String ||
        available is! bool ||
        rawState is! String ||
        (volume != null && (volume is! int || volume < 0 || volume > 100))) {
      throw const CoreCastRouteException('invalid_response');
    }
    final kind = CoreCastRouteKind.values
        .where((item) => item.name == rawKind)
        .firstOrNull;
    final state = CoreCastConnectionState.values
        .where((item) => item.name == rawState)
        .firstOrNull;
    if (kind == null || state == null) {
      throw const CoreCastRouteException('invalid_response');
    }
    return CoreCastRoute(
      id: id,
      name: name,
      kind: kind,
      available: available,
      connectionState: state,
      volumeLevel: volume as int?,
    );
  }

  final String id;
  final String name;
  final CoreCastRouteKind kind;
  final bool available;
  final CoreCastConnectionState connectionState;
  final int? volumeLevel;

  @override
  String toString() => 'CoreCastRoute(${kind.name}, ${connectionState.name})';
}

class CoreCastRouteSnapshot {
  const CoreCastRouteSnapshot({required this.revision, required this.routes});

  factory CoreCastRouteSnapshot.fromChannel(Object? value) {
    if (value is! Map<Object?, Object?> ||
        value.length != 2 ||
        !value.keys.every(const {'revision', 'routes'}.contains)) {
      throw const CoreCastRouteException('invalid_response');
    }
    final revision = value['revision'];
    final rawRoutes = value['routes'];
    if (revision is! int ||
        revision < 1 ||
        revision > 0x7fffffffffffffff ||
        rawRoutes is! List<Object?> ||
        rawRoutes.length > 64) {
      throw const CoreCastRouteException('invalid_response');
    }
    final routes = rawRoutes
        .map(CoreCastRoute.fromChannel)
        .toList(growable: false);
    if (routes.map((item) => item.id).toSet().length != routes.length) {
      throw const CoreCastRouteException('invalid_response');
    }
    return CoreCastRouteSnapshot(
      revision: revision,
      routes: List.unmodifiable(routes),
    );
  }

  final int revision;
  final List<CoreCastRoute> routes;

  @override
  String toString() =>
      'CoreCastRouteSnapshot(routes: ${routes.length}, revision: $revision)';
}

abstract interface class CoreCastRoutePlatform {
  bool get supported;
  Stream<CoreCastRouteSnapshot> get snapshots;
  Future<void> start();
  Future<void> stop();
}

class AndroidCoreCastRouteBridge implements CoreCastRoutePlatform {
  AndroidCoreCastRouteBridge({
    MethodChannel? methods,
    EventChannel? events,
    bool? isAndroid,
  }) : _methods = methods ?? const MethodChannel(methodChannelName),
       _events = events ?? const EventChannel(eventChannelName),
       _isAndroid =
           isAndroid ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const methodChannelName = 'com.ersingundem.larenor/core_cast_routes';
  static const eventChannelName =
      'com.ersingundem.larenor/core_cast_route_events';

  final MethodChannel _methods;
  final EventChannel _events;
  final bool _isAndroid;
  int _lastRevision = 0;

  @override
  bool get supported => _isAndroid;

  @override
  late final Stream<CoreCastRouteSnapshot> snapshots = _isAndroid
      ? _events.receiveBroadcastStream().map((value) {
          final snapshot = CoreCastRouteSnapshot.fromChannel(value);
          if (snapshot.revision <= _lastRevision) {
            throw const CoreCastRouteException('stale');
          }
          _lastRevision = snapshot.revision;
          return snapshot;
        })
      : const Stream<CoreCastRouteSnapshot>.empty();

  @override
  Future<void> start() => _call('start');

  @override
  Future<void> stop() => _call('stop');

  Future<void> _call(String method) async {
    if (!_isAndroid) throw const CoreCastRouteException('unsupported');
    try {
      final result = await _methods
          .invokeMethod<Object?>(method)
          .timeout(const Duration(seconds: 5));
      if (result != true) throw const CoreCastRouteException('unavailable');
    } on CoreCastRouteException {
      rethrow;
    } on TimeoutException {
      throw const CoreCastRouteException('timeout');
    } on PlatformException {
      throw const CoreCastRouteException('unavailable');
    } on MissingPluginException {
      throw const CoreCastRouteException('unsupported');
    }
  }
}
