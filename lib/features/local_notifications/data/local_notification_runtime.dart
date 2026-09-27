import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../server/domain/server_models.dart';
import '../domain/local_notification_models.dart';
import 'local_notification_api.dart';
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
  String? backgroundFailure;
  bool backgroundOutcomeUnknown = false;
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
  bool get canEnableBackground =>
      _capture() != null &&
      !_platformBusy &&
      controller.loaded &&
      !controller.busy &&
      controller.subscription != null &&
      platformStatus.canPresent;
  bool get canDisableBackground =>
      _capture() != null &&
      !_platformBusy &&
      controller.loaded &&
      !controller.busy &&
      controller.subscription != null &&
      platformStatus.backgroundDelivery != null;

  bool _routeActive() {
    try {
      return active();
    } catch (_) {
      return false;
    }
  }

  ServerSession? get _ready {
    final session = home.account.session;
    if (_disposed ||
        !_enabled ||
        !_routeActive() ||
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
        (!requireActive || _routeActive()) &&
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
    if (_disposed) return;
    final next = value && _routeActive();
    if (next == _enabled) return;
    _enabled = next;
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _platformBusy = false;
    _lastReconcile = null;
    backgroundFailure = null;
    backgroundOutcomeUnknown = false;
    controller.setVisible(next);
    if (next) {
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
    backgroundFailure = null;
    backgroundOutcomeUnknown = false;
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
    final shouldEnable = !_disposed && _routeActive();
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

  DateTime _deliveryExpiry(LocalNotificationSubscription subscription) {
    final now = clock().toUtc();
    final requested = now.add(const Duration(days: 30));
    final expiry = subscription.expiresAt.isBefore(requested)
        ? subscription.expiresAt
        : requested;
    if (!expiry.isAfter(now.add(const Duration(minutes: 1)))) {
      throw const LarenorServerException(
        'notification_delivery_authority_inactive',
      );
    }
    return expiry;
  }

  String _failureCode(Object error) => switch (error) {
    LarenorServerException value => value.code,
    _ => 'connection_failed',
  };

  bool _unknownOutcome(String code) => {
    'connection_failed',
    'request_timeout',
    'timeout',
    'server_error',
    'notification_storage_unavailable',
  }.contains(code);

  Future<AndroidNotificationStatus> _probeCurrent(
    _RuntimeAuthority authority,
    bool Function() interactionCurrent,
  ) => platform.probe(current: () => _same(authority) && interactionCurrent());

  Future<bool> enableOrRecoverBackgroundDelivery({
    required bool Function() interactionCurrent,
  }) async {
    final authority = _capture(), subscription = controller.subscription;
    if (authority == null ||
        subscription == null ||
        !canEnableBackground ||
        !interactionCurrent()) {
      return false;
    }
    bool current() {
      try {
        return _same(authority) && interactionCurrent();
      } catch (_) {
        return false;
      }
    }

    _platformBusy = true;
    backgroundFailure = null;
    backgroundOutcomeUnknown = false;
    notifyListeners();
    final transport = controller.apiFactory(authority.session.endpoint);
    final api = LocalNotificationApi(
      transport,
      authority.session,
      isCurrent: current,
    );
    var serverMutationStarted = false;
    try {
      final local = platformStatus.backgroundDelivery;
      LocalNotificationDeliveryLease lease;
      if (local?.active == true) {
        lease = await api.getDeliveryLease(
          leaseId: local!.leaseId,
          subscriptionId: subscription.id,
          credentialFingerprint: local.credentialFingerprint,
        );
        if (lease.state != LocalNotificationDeliveryLeaseState.active ||
            lease.revision < local.leaseRevision ||
            lease.subscriptionRevision < local.subscriptionRevision ||
            lease.subscriptionRevision > subscription.revision) {
          throw const LarenorServerException(
            'notification_delivery_authority_inactive',
          );
        }
        final now = clock().toUtc();
        final renew =
            lease.subscriptionRevision != subscription.revision ||
            lease.expiresAt.isBefore(now.add(const Duration(days: 7)));
        if (renew) {
          serverMutationStarted = true;
          lease = await api.renewDeliveryLease(
            lease,
            subscription,
            expiresAt: _deliveryExpiry(subscription),
          );
          serverMutationStarted = false;
        }
      } else {
        final registration = await platform.prepareBackgroundDelivery(
          session: authority.session,
          subscription: subscription,
          expiresAt: _deliveryExpiry(subscription),
          current: current,
        );
        if (local != null &&
            (local.leaseId != registration.leaseId ||
                local.credentialFingerprint !=
                    registration.credentialFingerprint ||
                local.subscriptionRevision !=
                    registration.expectedSubscriptionRevision)) {
          throw const LarenorServerException('invalid_response');
        }
        try {
          lease = await api.getDeliveryLease(
            leaseId: registration.leaseId,
            subscriptionId: subscription.id,
            credentialFingerprint: registration.credentialFingerprint,
          );
        } on LarenorServerException catch (error) {
          if (error.code != 'not_found') rethrow;
          serverMutationStarted = true;
          lease = await api.registerDeliveryLease(subscription, registration);
          serverMutationStarted = false;
        }
        if (lease.state != LocalNotificationDeliveryLeaseState.active) {
          throw const LarenorServerException(
            'notification_delivery_authority_inactive',
          );
        }
      }
      if (local?.active == true &&
          local!.subscriptionRevision != lease.subscriptionRevision) {
        if (lease.subscriptionRevision != subscription.revision) {
          throw const LarenorServerException('invalid_response');
        }
        platformStatus = await platform.reconcile(
          session: authority.session,
          subscription: subscription,
          events: controller.events,
          current: current,
        );
      }
      if (!current()) return false;
      await platform.activateBackgroundDelivery(lease: lease, current: current);
      if (!current()) return false;
      platformStatus = await _probeCurrent(authority, interactionCurrent);
      if (!platformStatus.backgroundActive ||
          platformStatus.backgroundDelivery?.leaseId != lease.id ||
          platformStatus.backgroundDelivery?.leaseRevision != lease.revision) {
        throw const LarenorServerException('invalid_response');
      }
      return true;
    } catch (error) {
      if (current()) {
        final code = _failureCode(error);
        backgroundFailure = code;
        backgroundOutcomeUnknown =
            serverMutationStarted && _unknownOutcome(code);
      }
      return false;
    } finally {
      api.retire();
      transport.close();
      if (!_disposed && authority.runtimeEpoch == _epoch) {
        _platformBusy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> disableBackgroundDelivery({
    required bool Function() interactionCurrent,
  }) async {
    final authority = _capture(),
        subscription = controller.subscription,
        initial = platformStatus.backgroundDelivery;
    if (authority == null ||
        subscription == null ||
        initial == null ||
        !canDisableBackground ||
        !interactionCurrent()) {
      return false;
    }
    bool current() {
      try {
        return _same(authority) && interactionCurrent();
      } catch (_) {
        return false;
      }
    }

    _platformBusy = true;
    backgroundFailure = null;
    backgroundOutcomeUnknown = false;
    notifyListeners();
    final transport = controller.apiFactory(authority.session.endpoint);
    final api = LocalNotificationApi(
      transport,
      authority.session,
      isCurrent: current,
    );
    var revokeStarted = false;
    try {
      LocalNotificationDeliveryLease? lease;
      try {
        lease = await api.getDeliveryLease(
          leaseId: initial.leaseId,
          subscriptionId: subscription.id,
          credentialFingerprint: initial.credentialFingerprint,
        );
      } on LarenorServerException catch (error) {
        if (error.code != 'not_found') rethrow;
      }
      var local = initial;
      if (lease?.state == LocalNotificationDeliveryLeaseState.active) {
        if (lease!.revision < initial.leaseRevision ||
            lease.subscriptionRevision < initial.subscriptionRevision) {
          throw const LarenorServerException('invalid_response');
        }
        revokeStarted = true;
        await api.revokeDeliveryLease(lease);
        revokeStarted = false;
      }
      if (!current()) return false;
      if (local.active) {
        await platform.disableBackgroundDelivery(
          delivery: local,
          current: current,
        );
      } else {
        await platform.cancelPreparedBackgroundDelivery(
          delivery: local,
          current: current,
        );
      }
      if (!current()) return false;
      platformStatus = await _probeCurrent(authority, interactionCurrent);
      if (platformStatus.backgroundDelivery != null ||
          platformStatus.deliveryMode != 'foregroundPull') {
        throw const LarenorServerException('invalid_response');
      }
      return true;
    } catch (error) {
      if (current()) {
        final code = _failureCode(error);
        backgroundFailure = code;
        backgroundOutcomeUnknown = revokeStarted && _unknownOutcome(code);
      }
      return false;
    } finally {
      api.retire();
      transport.close();
      if (!_disposed && authority.runtimeEpoch == _epoch) {
        _platformBusy = false;
        notifyListeners();
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
