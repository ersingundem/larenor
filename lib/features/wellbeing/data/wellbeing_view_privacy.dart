import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/wellbeing_models.dart';

abstract interface class WellbeingViewPrivacyBridge {
  Future<void> setPrivateView(bool enabled);
}

class ChannelWellbeingViewPrivacyBridge implements WellbeingViewPrivacyBridge {
  static const _channel = MethodChannel('larenor/wellbeing');
  @override
  Future<void> setPrivateView(bool enabled) async {
    // Other platforms retain the PIN/masking guard. This does not promise an
    // OS screenshot block on platforms without the Android window contract.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('setPrivateView', enabled);
  }
}

final wellbeingViewPrivacyBridgeProvider = Provider<WellbeingViewPrivacyBridge>(
  (_) => ChannelWellbeingViewPrivacyBridge(),
);
final wellbeingViewPrivacyProvider = Provider<WellbeingViewPrivacy>((ref) {
  final privacy = WellbeingViewPrivacy(
    ref.watch(wellbeingViewPrivacyBridgeProvider),
  );
  ref.onDispose(privacy.dispose);
  return privacy;
});

/// One owner across route replacements. A late old-route release must never
/// remove the secure flag of a newly authenticated private page.
class WellbeingViewPrivacy {
  WellbeingViewPrivacy(this._bridge) {
    _lifecycle = AppLifecycleListener(
      onResume: () {
        WidgetsBinding.instance.addPostFrameCallback((_) => _flush());
      },
    );
  }
  final WellbeingViewPrivacyBridge _bridge;
  late final AppLifecycleListener _lifecycle;
  Future<void> _pending = Future.value();
  Object? _owner;
  bool _disposed = false;

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> acquire(Object owner, {required bool Function() isCurrent}) =>
      _serial(() async {
        if (_disposed || !isCurrent()) {
          throw const WellbeingException(WellbeingFailure.locked);
        }
        await _bridge.setPrivateView(true);
        if (_disposed || !isCurrent()) {
          if (_owner == null) await _bridge.setPrivateView(false);
          throw const WellbeingException(WellbeingFailure.locked);
        }
        _owner = owner;
      });

  /// Invoke only after the old private subtree has been removed and painted.
  Future<void> release(Object owner) => _serial(() async {
    if (!identical(_owner, owner)) return;
    _owner = null;
    await _bridge.setPrivateView(false);
  });

  void _flush() {
    _serial(() async {
      if (_disposed || _owner != null) return;
      // Native background releases remain protected until a masked foreground
      // frame exists. Repeat false after that frame to complete the release.
      await _bridge.setPrivateView(false);
    }).catchError((Object _) {});
  }

  void dispose() {
    _disposed = true;
    _lifecycle.dispose();
    final owner = _owner;
    if (owner != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        release(owner).catchError((Object _) {});
      });
    }
  }
}
