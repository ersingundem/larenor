import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'window_policy_models.dart';

/// A transient request, not proof that Android hid its bars or entered kiosk.
class WindowFullscreenLease {
  const WindowFullscreenLease._({
    required this.owner,
    required this.revision,
    required this.display,
    required this.acquisition,
  });
  final String owner;
  final int revision;
  final WindowDisplayIdentity display;
  final WindowPolicySnapshot acquisition;
}

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

  Future<WindowFullscreenLease?> acquireFullscreen(
    WindowDisplayIdentity display,
  ) async {
    if (!_isAndroid ||
        display.isExternalDisplay ||
        display.displayId < 0 ||
        display.displayRevision < 1 ||
        display.displayRevision > 9007199254740991) {
      return null;
    }
    final random = Random.secure();
    final owner = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    try {
      final raw = await _methods.invokeMethod<Object?>('acquireFullscreen', {
        'owner': owner,
        'displayId': display.displayId,
        'displayRevision': display.displayRevision,
      });
      if (raw is! Map ||
          raw.length != 4 ||
          !raw.keys.every(
            const {
              'schemaVersion',
              'accepted',
              'revision',
              'snapshot',
            }.contains,
          ) ||
          raw['schemaVersion'] != 1 ||
          raw['accepted'] is! bool) {
        throw const FormatException('Invalid fullscreen response');
      }
      final snapshot = WindowPolicySnapshot.fromChannel(raw['snapshot']);
      if (raw['accepted'] == false) {
        if (raw['revision'] != null) {
          throw const FormatException('Invalid fullscreen response');
        }
        return null;
      }
      final revision = raw['revision'];
      if (revision is! int ||
          revision < 1 ||
          revision > 9007199254740991 ||
          !snapshot.supported ||
          !snapshot.isResumed ||
          !snapshot.hasWindowFocus ||
          snapshot.isMultiWindow ||
          snapshot.isPictureInPicture ||
          snapshot.captionVisible != false ||
          snapshot.imeVisible != false ||
          snapshot.reason != WindowRestrictionReason.none ||
          snapshot.displayIdentity != display ||
          snapshot.effectiveMode != WindowEffectiveMode.panelRequested) {
        throw const FormatException('Invalid fullscreen response');
      }
      return WindowFullscreenLease._(
        owner: owner,
        revision: revision,
        display: display,
        acquisition: snapshot,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      await _cancelFullscreen(owner);
      return null;
    } on FormatException {
      await _cancelFullscreen(owner);
      return null;
    }
  }

  Future<bool> releaseFullscreen(WindowFullscreenLease lease) async {
    if (!_isAndroid) return false;
    try {
      return await _methods.invokeMethod<Object?>('releaseFullscreen', {
            'owner': lease.owner,
            'revision': lease.revision,
          }) ==
          true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _cancelFullscreen(String owner) async {
    try {
      await _methods.invokeMethod<Object?>('cancelFullscreen', {
        'owner': owner,
      });
    } on MissingPluginException {
      // No native owner exists when the plugin is absent.
    } on PlatformException {
      // Lifecycle/display loss also retires this exact transient owner.
    }
  }

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
          onDone: () {
            scheduleMicrotask(() {
              if (cancelled) return;
              sink.add(WindowPolicySnapshot.unknown);
              sink.close();
            });
          },
        );
      });
      sink.onCancel = () {
        cancelled = true;
        return listener?.cancel();
      };
    }, isBroadcast: true);
  }
}
