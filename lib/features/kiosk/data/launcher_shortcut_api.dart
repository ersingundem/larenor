import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../domain/launcher_shortcut_models.dart';

abstract interface class LauncherShortcutApi {
  Future<LauncherShortcutAction?> takeInitial();
  Stream<LauncherShortcutAction> get actions;
}

final class AndroidLauncherShortcutApi implements LauncherShortcutApi {
  AndroidLauncherShortcutApi({
    MethodChannel? methods,
    EventChannel? events,
    bool? isAndroid,
  }) : _methods = methods ?? const MethodChannel(methodChannelName),
       _events = events ?? const EventChannel(eventChannelName),
       _android = isAndroid ?? Platform.isAndroid;

  static const methodChannelName = 'com.ersingundem.larenor/launcher_shortcuts';
  static const eventChannelName =
      'com.ersingundem.larenor/launcher_shortcut_events';
  final MethodChannel _methods;
  final EventChannel _events;
  final bool _android;

  @override
  Future<LauncherShortcutAction?> takeInitial() async {
    if (!_android) return null;
    try {
      final raw = await _methods
          .invokeMethod<Object?>('takeInitial')
          .timeout(const Duration(seconds: 5));
      if (raw == null) return null;
      return LauncherShortcutAction.parse(raw) ??
          (throw const LauncherShortcutException());
    } on MissingPluginException {
      return null;
    } on LauncherShortcutException {
      rethrow;
    } catch (_) {
      throw const LauncherShortcutException();
    }
  }

  @override
  Stream<LauncherShortcutAction> get actions {
    if (!_android) return const Stream.empty();
    return _events.receiveBroadcastStream().map((raw) {
      return LauncherShortcutAction.parse(raw) ??
          (throw const LauncherShortcutException());
    });
  }
}
