/// A presentation preference, never a device-owner or kiosk authorization.
enum WindowProfile { adaptive, panel }

enum WindowEffectiveMode { adaptive, panelRequested, restricted, unknown }

enum WindowRestrictionReason {
  none,
  unsupported,
  notForeground,
  noFocus,
  multiWindow,
  pictureInPicture,
  captionBar,
  desktopMode,
  externalDisplay,
  keyboard,
  unknown,
}

enum WindowLockTaskState { none, pinned, locked, unknown }

/// Observations describe the current Activity; a hide request is not proof
/// that Android has hidden its bars or locked the device.
class WindowPolicySnapshot {
  const WindowPolicySnapshot({
    this.supported = false,
    this.requestedProfile = WindowProfile.adaptive,
    this.effectiveMode = WindowEffectiveMode.unknown,
    this.reason = WindowRestrictionReason.unsupported,
    this.isResumed = false,
    this.hasWindowFocus = false,
    this.isMultiWindow = false,
    this.isPictureInPicture = false,
    this.isExternalDisplay = false,
    this.captionVisible,
    this.imeVisible,
    this.statusBarVisible,
    this.navigationBarVisible,
    this.lockTaskPermitted,
    this.lockTaskState = WindowLockTaskState.unknown,
  });

  final bool supported;
  final WindowProfile requestedProfile;
  final WindowEffectiveMode effectiveMode;
  final WindowRestrictionReason reason;
  final bool isResumed;
  final bool hasWindowFocus;
  final bool isMultiWindow;
  final bool isPictureInPicture;
  final bool isExternalDisplay;
  final bool? captionVisible;
  final bool? imeVisible;
  final bool? statusBarVisible;
  final bool? navigationBarVisible;
  final bool? lockTaskPermitted;
  final WindowLockTaskState lockTaskState;

  static const unknown = WindowPolicySnapshot(
    supported: true,
    reason: WindowRestrictionReason.unknown,
  );

  factory WindowPolicySnapshot.fromChannel(Object? raw) {
    if (raw is! Map || raw.length != 15) _invalid();
    bool requiredBool(String key) {
      final value = raw[key];
      if (value is! bool) _invalid();
      return value;
    }

    bool? optionalBool(String key) {
      if (!raw.containsKey(key)) _invalid();
      final value = raw[key];
      if (value != null && value is! bool) _invalid();
      return value as bool?;
    }

    T enumeration<T extends Enum>(String key, List<T> values) {
      final value = raw[key];
      for (final item in values) {
        if (item.name == value) return item;
      }
      _invalid();
    }

    return WindowPolicySnapshot(
      supported: requiredBool('supported'),
      requestedProfile: enumeration('requestedProfile', WindowProfile.values),
      effectiveMode: enumeration('effectiveMode', WindowEffectiveMode.values),
      reason: enumeration('reason', WindowRestrictionReason.values),
      isResumed: requiredBool('isResumed'),
      hasWindowFocus: requiredBool('hasWindowFocus'),
      isMultiWindow: requiredBool('isMultiWindow'),
      isPictureInPicture: requiredBool('isPictureInPicture'),
      isExternalDisplay: requiredBool('isExternalDisplay'),
      captionVisible: optionalBool('captionVisible'),
      imeVisible: optionalBool('imeVisible'),
      statusBarVisible: optionalBool('statusBarVisible'),
      navigationBarVisible: optionalBool('navigationBarVisible'),
      lockTaskPermitted: optionalBool('lockTaskPermitted'),
      lockTaskState: enumeration('lockTaskState', WindowLockTaskState.values),
    );
  }

  static Never _invalid() =>
      throw const FormatException('Invalid window policy response');
}
