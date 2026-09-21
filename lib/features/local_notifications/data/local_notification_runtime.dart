import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/domain/server_models.dart';
import '../domain/local_notification_models.dart';
import 'local_notification_controller.dart';
import 'local_notification_platform.dart';

typedef LocalNotificationNavigate = void Function(String location);

final class LocalNotificationRuntimeCoordinator extends ChangeNotifier {
  LocalNotificationRuntimeCoordinator({
    required this.home,
    required this.controller,
    required this.platform,
    required this.clock,
    required this.active,
    required this.navigate,
    this.pollInterval = const Duration(minutes: 1),
  }) {
    controller.addListener(_inboxChanged);
    home.addListener(authorityChanged);
    home.account.addListener(authorityChanged);
    _tapSubscription = platform.taps.listen(
      _tap,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  final HomeSessionController home;
  final LocalNotificationController controller;
  final LocalNotificationPlatform platform;
  final DateTime Function() clock;
  final bool Function() active;
  final LocalNotificationNavigate navigate;
  final Duration pollInterval;
  StreamSubscription<LocalNotificationTap>? _tapSubscription;
  final ListQueue<LocalNotificationTap> _pendingTaps = ListQueue();
  final ListQueue<String> _consumedTaps = ListQueue();
  Timer? _timer;
  bool _enabled = false,
      _disposed = false,
      _platformBusy = false,
      _permissionPending = false;
  int _epoch = 0;
  String? _lastReconcile;
  AndroidNotificationStatus platformStatus = const AndroidNotificationStatus(
    permission: AndroidNotificationPermission.unsupported,
    channelEnabled: false,
    recoveryRequired: false,
    batteryOptimizationExempt: false,
    deliveryMode: 'unsupported',
  );

  bool get enabled => _enabled;
  bool get platformBusy => _platformBusy;
  bool get permissionPending => _permissionPending;

  ServerSession? get _ready {
    final session = home.account.session;
    if (_disposed ||
        !_enabled ||
        !active() ||
        home.source != HomeSource.verifiedCore ||
        home.busy ||
        home.failure != null ||
        !home.interaction.active ||
        !home.account.initialized ||
        home.account.working ||
        home.account.hasPendingContext ||
        session == null ||
        session.context == null ||
        session.authMutationPending ||
        session.user.mustChangePassword ||
        session.expiresSoon(clock())) {
      return null;
    }
    return session;
  }

  _RuntimeAuthority? _capture() {
    final session = _ready;
    if (session == null) return null;
    return _RuntimeAuthority(
      session: session,
      accountGeneration: home.account.generation,
      interactionEpoch: home.interaction.epoch,
      runtimeEpoch: _epoch,
    );
  }

  bool _same(_RuntimeAuthority authority, {bool requireActive = true}) {
    final current = home.account.session;
    return !_disposed &&
        home.source == HomeSource.verifiedCore &&
        !home.busy &&
        home.failure == null &&
        (!requireActive || _enabled) &&
        (!requireActive || active()) &&
        _epoch == authority.runtimeEpoch &&
        home.account.isCurrent(authority.accountGeneration) &&
        identical(current, authority.session) &&
        current?.context == authority.session.context &&
        current?.user.id == authority.session.user.id &&
        (!requireActive ||
            home.interaction.active &&
                home.interaction.epoch == authority.interactionEpoch);
  }

  void setEnabled(bool value) {
    if (_disposed || value == _enabled) return;
    _enabled = value;
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _platformBusy = false;
    _lastReconcile = null;
    controller.setVisible(value);
    if (value) {
      _timer = Timer.periodic(pollInterval, (_) {
        if (_capture() != null && controller.canRefresh) {
          unawaited(controller.refresh());
        }
      });
      unawaited(_probe());
      unawaited(_consumeTaps());
    }
    notifyListeners();
  }

  void retire() {
    if (_disposed) return;
    _enabled = false;
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _platformBusy = false;
    _lastReconcile = null;
    controller.setVisible(false);
    notifyListeners();
  }

  /// The Android permission surface temporarily removes window focus. Pause
  /// inbox work without invalidating the exact account-bound system callback.
  /// App lifecycle loss still calls [setEnabled] and retires that callback.
  void suspendForPermissionDialog() {
    if (_disposed || !_enabled || !_permissionPending) return;
    _enabled = false;
    _timer?.cancel();
    _timer = null;
    _lastReconcile = null;
    controller.setVisible(false);
    notifyListeners();
  }

  void authorityChanged() {
    final shouldEnable = !_disposed && active();
    if (!shouldEnable) {
      setEnabled(false);
    } else if (!_enabled) {
      setEnabled(true);
    } else if (_ready == null) {
      _epoch++;
      _lastReconcile = null;
      controller.setVisible(false);
      _enabled = false;
      notifyListeners();
    }
  }

  Future<void> _probe() async {
    final authority = _capture();
    if (authority == null || _platformBusy) return;
    _platformBusy = true;
    var shouldReconcile = false;
    notifyListeners();
    try {
      final next = await platform.probe(current: () => _same(authority));
      if (!_same(authority)) return;
      platformStatus = next;
      shouldReconcile = next.canPresent;
    } catch (_) {
      // The in-app inbox remains authoritative when Android is unavailable.
    } finally {
      if (!_disposed && authority.runtimeEpoch == _epoch) {
        _platformBusy = false;
        notifyListeners();
        if (shouldReconcile && _same(authority)) unawaited(_reconcile());
      }
    }
  }

  void _inboxChanged() {
    if (_disposed) return;
    notifyListeners();
    if (_capture() != null &&
        controller.loaded &&
        !controller.busy &&
        platformStatus.canPresent) {
      unawaited(_reconcile());
    }
    if (_pendingTaps.isNotEmpty) unawaited(_consumeTaps());
  }

  Future<void> _reconcile() async {
    final authority = _capture(), subscription = controller.subscription;
    if (authority == null ||
        subscription == null ||
        !controller.loaded ||
        controller.busy ||
        _platformBusy ||
        !platformStatus.canPresent) {
      return;
    }
    final unread = controller.events
        .where((event) => event.readState == LocalNotificationReadState.unread)
        .toList(growable: false);
    final signature =
        '${AndroidLocalNotificationPlatform.bindingId(authority.session)}:'
        '${subscription.id}:${subscription.revision}:'
        '${unread.map((event) => '${event.sequence}:${event.id}').join(',')}';
    if (signature == _lastReconcile) return;
    _platformBusy = true;
    notifyListeners();
    try {
      final next = await platform.reconcile(
        session: authority.session,
        subscription: subscription,
        events: unread,
        current: () => _same(authority),
      );
      if (!_same(authority)) return;
      platformStatus = next;
      _lastReconcile = signature;
    } catch (_) {
      // A native failure never changes Core inbox state or retries in a loop.
    } finally {
      if (!_disposed && authority.runtimeEpoch == _epoch) {
        _platformBusy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> requestPermission({
    required bool Function() interactionCurrent,
  }) async {
    final authority = _capture();
    if (authority == null || _platformBusy || !interactionCurrent()) {
      return false;
    }
    _platformBusy = true;
    _permissionPending = true;
    var shouldReconcile = false;
    notifyListeners();
    try {
      final next = await platform.requestPermission(
        current: () => _same(authority, requireActive: false),
      );
      if (!_same(authority, requireActive: false)) return false;
      platformStatus = next;
      _lastReconcile = null;
      shouldReconcile = next.canPresent;
      return true;
    } catch (_) {
      return false;
    } finally {
      _permissionPending = false;
      if (!_disposed && authority.runtimeEpoch == _epoch) {
        _platformBusy = false;
        notifyListeners();
        if (shouldReconcile && _same(authority)) unawaited(_reconcile());
      }
    }
  }

  Future<void> openNotificationSettings({required bool Function() current}) =>
      _open(platform.openNotificationSettings, current);
  Future<void> openPowerSettings({required bool Function() current}) =>
      _open(platform.openPowerSettings, current);
  Future<void> _open(
    Future<void> Function({required bool Function() current}) action,
    bool Function() interactionCurrent,
  ) async {
    final authority = _capture();
    if (authority == null || _platformBusy || !interactionCurrent()) return;
    try {
      await action(current: () => _same(authority) && interactionCurrent());
    } catch (_) {}
  }

  void _tap(LocalNotificationTap tap) {
    if (_disposed) return;
    final key =
        '${tap.bindingId}:${tap.subscriptionRevision}:${tap.sequence}:${tap.eventId}';
    if (_consumedTaps.contains(key) ||
        _pendingTaps.any(
          (item) =>
              item.bindingId == tap.bindingId &&
              item.subscriptionRevision == tap.subscriptionRevision &&
              item.sequence == tap.sequence &&
              item.eventId == tap.eventId,
        )) {
      return;
    }
    if (_pendingTaps.length >= 8) _pendingTaps.removeFirst();
    _pendingTaps.addLast(tap);
    unawaited(_consumeTaps());
  }

  Future<void> _consumeTaps() async {
    if (_disposed || _platformBusy || _pendingTaps.isEmpty) return;
    final authority = _capture(), subscription = controller.subscription;
    if (authority == null ||
        subscription == null ||
        !controller.loaded ||
        controller.busy) {
      if (authority != null && controller.canRefresh) {
        unawaited(controller.refresh());
      }
      return;
    }
    final tap = _pendingTaps.first;
    final binding = AndroidLocalNotificationPlatform.bindingId(
      authority.session,
    );
    final matches = controller.events
        .where(
          (event) => event.id == tap.eventId && event.sequence == tap.sequence,
        )
        .toList(growable: false);
    if (tap.bindingId != binding ||
        tap.subscriptionRevision != subscription.revision ||
        matches.length != 1 ||
        matches.single.readState != LocalNotificationReadState.unread) {
      _pendingTaps.removeFirst();
      unawaited(_consumeTaps());
      return;
    }
    final event = matches.single;
    _platformBusy = true;
    notifyListeners();
    bool current() =>
        _same(authority) &&
        _pendingTaps.isNotEmpty &&
        identical(_pendingTaps.first, tap) &&
        controller.events
                .where(
                  (item) =>
                      item.id == tap.eventId && item.sequence == tap.sequence,
                )
                .firstOrNull
                ?.sameEnvelope(event) ==
            true;
    try {
      final acknowledged = await controller.markRead(
        event,
        interactionCurrent: current,
      );
      if (!acknowledged || !current()) return;
      final route = LocalNotificationRoutePolicy.allowed(event.target);
      if (route == null) return;
      _pendingTaps.removeFirst();
      final key =
          '${tap.bindingId}:${tap.subscriptionRevision}:${tap.sequence}:${tap.eventId}';
      if (_consumedTaps.length >= 64) _consumedTaps.removeFirst();
      _consumedTaps.addLast(key);
      _lastReconcile = null;
      final readback = controller.events
          .where(
            (item) => item.id == tap.eventId && item.sequence == tap.sequence,
          )
          .firstOrNull;
      if (_same(authority) &&
          readback?.sameEnvelope(event) == true &&
          readback?.readState == LocalNotificationReadState.read) {
        navigate(route);
      }
    } finally {
      if (_pendingTaps.isNotEmpty && identical(_pendingTaps.first, tap)) {
        _pendingTaps.removeFirst();
      }
      if (!_disposed && authority.runtimeEpoch == _epoch) {
        _platformBusy = false;
        notifyListeners();
        if (_same(authority)) unawaited(_reconcile());
        unawaited(_consumeTaps());
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _timer?.cancel();
    unawaited(_tapSubscription?.cancel());
    controller.removeListener(_inboxChanged);
    home.removeListener(authorityChanged);
    home.account.removeListener(authorityChanged);
    controller.dispose();
    _pendingTaps.clear();
    _consumedTaps.clear();
    super.dispose();
  }
}

final class _RuntimeAuthority {
  const _RuntimeAuthority({
    required this.session,
    required this.accountGeneration,
    required this.interactionEpoch,
    required this.runtimeEpoch,
  });
  final ServerSession session;
  final int accountGeneration, interactionEpoch, runtimeEpoch;
}
