import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'window_policy_models.dart';

class WindowPolicyBridge {
  WindowPolicyBridge({
    MethodChannel? methods,
    EventChannel? events,
    bool? isAndroid,
  }) : _methods = methods ?? const MethodChannel(methodChannelName),
       _events = events ?? const EventChannel(eventChannelName),
       _isAndroid =
           isAndroid ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const methodChannelName = 'com.ersingundem.larenor/window_policy';
  static const eventChannelName = '${methodChannelName}_events';
  final MethodChannel _methods;
  final EventChannel _events;
  final bool _isAndroid;

  Future<WindowPolicySnapshot> snapshot() => _invoke('snapshot');
  Future<WindowPolicySnapshot> setProfile(WindowProfile profile) =>
      _invoke('setProfile', {'profile': profile.name});

  Future<WindowPolicySnapshot> _invoke(String method, [Object? payload]) async {
    if (!_isAndroid) return const WindowPolicySnapshot();
    try {
      return WindowPolicySnapshot.fromChannel(
        await _methods.invokeMethod<Object?>(method, payload),
      );
    } on MissingPluginException {
      return const WindowPolicySnapshot();
    } on PlatformException {
      return WindowPolicySnapshot.unknown;
    } on FormatException {
      return WindowPolicySnapshot.unknown;
    }
  }

  /// The shared native observer survives individual UI subscriptions. No
  /// polling, system settings action, or profile write is started by listening.
  late final Stream<WindowPolicySnapshot> changes = _nativeChanges();

  Stream<WindowPolicySnapshot> _nativeChanges() {
    final native = _events.receiveBroadcastStream();
    return Stream.multi((sink) {
      StreamSubscription<dynamic>? listener;
      var cancelled = false;
      snapshot().then((initial) {
        if (cancelled) return;
        sink.add(initial);
        if (!initial.supported) {
          sink.close();
          return;
        }
        listener = native.listen(
          (raw) {
            try {
              sink.add(WindowPolicySnapshot.fromChannel(raw));
            } on FormatException {
              sink.add(WindowPolicySnapshot.unknown);
            }
          },
          onError: (Object _) => sink.add(WindowPolicySnapshot.unknown),
          onDone: sink.close,
        );
      });
      sink.onCancel = () {
        cancelled = true;
        return listener?.cancel();
      };
    }, isBroadcast: true);
  }
}
