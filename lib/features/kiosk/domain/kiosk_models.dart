enum KioskAction { allowApp, removeApp, restorePowerMenu, enter, exit }

enum KioskLockState { none, pinned, locked, unknown }

enum KioskOutcome { observed, accepted, unknown }

enum KioskFailure {
  unsupported,
  unavailable,
  denied,
  expired,
  busy,
  pinRequired,
  wrongPin,
  rateLimited,
}

class KioskException implements Exception {
  const KioskException(this.failure, {this.retryAfter = Duration.zero});
  final KioskFailure failure;
  final Duration retryAfter;
  @override
  String toString() => 'Kiosk action unavailable';
}

class KioskSnapshot {
  KioskSnapshot({
    required this.supported,
    this.deviceOwner,
    this.permitted,
    this.lockState = KioskLockState.unknown,
    this.resumed = false,
    this.focused = false,
    this.eligibleWindow = false,
    this.keyguardLocked,
    this.powerMenuAllowed,
    this.allowlistCount,
    Set<KioskAction> actions = const {},
  }) : actions = Set.unmodifiable(actions);
  final bool supported, resumed, focused, eligibleWindow;
  final bool? deviceOwner, permitted, keyguardLocked, powerMenuAllowed;
  final int? allowlistCount;
  final KioskLockState lockState;
  final Set<KioskAction> actions;
  factory KioskSnapshot.fromChannel(Object? raw) {
    Never invalid() => throw const KioskException(KioskFailure.unavailable);
    if (raw is! Map || raw.length != 11) invalid();
    bool boolean(String key) {
      final v = raw[key];
      if (v is! bool) invalid();
      return v;
    }

    bool? optionalBool(String key) {
      if (!raw.containsKey(key)) invalid();
      final v = raw[key];
      if (v != null && v is! bool) invalid();
      return v as bool?;
    }

    final state = KioskLockState.values
        .where((v) => v.name == raw['lockState'])
        .firstOrNull;
    final count = raw['allowlistCount'];
    final values = raw['actions'];
    if (state == null ||
        (count != null && (count is! int || count < 0 || count > 10000)) ||
        values is! List ||
        values.length > KioskAction.values.length ||
        values.toSet().length != values.length) {
      invalid();
    }
    final actions = <KioskAction>{};
    for (final name in values) {
      final action = KioskAction.values
          .where((v) => v.name == name)
          .firstOrNull;
      if (action == null) invalid();
      actions.add(action);
    }
    return KioskSnapshot(
      supported: boolean('supported'),
      deviceOwner: optionalBool('deviceOwner'),
      permitted: optionalBool('permitted'),
      lockState: state,
      resumed: boolean('resumed'),
      focused: boolean('focused'),
      eligibleWindow: boolean('eligibleWindow'),
      keyguardLocked: optionalBool('keyguardLocked'),
      powerMenuAllowed: optionalBool('powerMenuAllowed'),
      allowlistCount: count as int?,
      actions: actions,
    );
  }
}

class KioskIntent {
  KioskIntent({required this.id, required this.action, required this.snapshot});
  final String id;
  final KioskAction action;
  final KioskSnapshot snapshot;
  factory KioskIntent.fromChannel(Object? raw, KioskAction expected) {
    if (raw is! Map ||
        raw.length != 3 ||
        raw['action'] != expected.name ||
        raw['id'] is! String ||
        !RegExp(r'^[a-zA-Z0-9-]{16,80}$').hasMatch(raw['id'] as String)) {
      throw const KioskException(KioskFailure.unavailable);
    }
    final snapshot = KioskSnapshot.fromChannel(raw['snapshot']);
    if (!snapshot.supported || !snapshot.actions.contains(expected)) {
      throw const KioskException(KioskFailure.unavailable);
    }
    return KioskIntent(
      id: raw['id'] as String,
      action: expected,
      snapshot: snapshot,
    );
  }
  @override
  String toString() => 'Kiosk confirmation';
}

class KioskReceipt {
  const KioskReceipt(this.outcome, this.snapshot);
  final KioskOutcome outcome;
  final KioskSnapshot? snapshot;
  factory KioskReceipt.fromChannel(Object? raw) {
    if (raw is! Map || raw.length != 2) {
      throw const KioskException(KioskFailure.unavailable);
    }
    final outcome = KioskOutcome.values
        .where((v) => v.name == raw['outcome'])
        .firstOrNull;
    if (outcome == null ||
        (raw['snapshot'] == null && outcome != KioskOutcome.unknown)) {
      throw const KioskException(KioskFailure.unavailable);
    }
    return KioskReceipt(
      outcome,
      raw['snapshot'] == null
          ? null
          : KioskSnapshot.fromChannel(raw['snapshot']),
    );
  }
}
