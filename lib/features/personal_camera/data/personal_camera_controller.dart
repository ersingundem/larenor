import 'dart:async';

import 'package:flutter/foundation.dart';

import 'personal_camera_platform.dart';

/// Owns one explicit foreground preview. A retired native session is never
/// reopened automatically and an uncertain close fences every later open.
final class PersonalCameraController extends ChangeNotifier {
  PersonalCameraController({
    required this.platform,
    required this.isCurrent,
    this.closeTimeout = const Duration(seconds: 5),
  });

  final PersonalCameraPlatform platform;
  final bool Function() isCurrent;
  final Duration closeTimeout;
  PersonalCameraSession? _session;
  StreamSubscription<PersonalCameraEvent>? _events;
  Future<bool>? _closing;
  int _epoch = 0;
  bool _disposed = false;
  bool opening = false;
  PersonalCameraFailure? failure;

  PersonalCameraSession? get session => _session;
  bool get opened => _session != null;
  bool get canOpen =>
      !_disposed && !opening && !opened && _closing == null && _current();

  bool _current() {
    try {
      return !_disposed && isCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<void> open() async {
    if (!canOpen) return;
    final operation = ++_epoch;
    PersonalCameraEvent? earlyEvent;
    var earlyError = false;
    opening = true;
    failure = null;
    notifyListeners();
    final events = platform.events.listen(
      (event) {
        if (operation != _epoch) return;
        if (_session == null) {
          earlyEvent = event;
        } else {
          _nativeEvent(operation, event);
        }
      },
      onError: (_) {
        if (operation != _epoch) return;
        if (_session == null) {
          earlyError = true;
        } else {
          _nativeFailure(operation);
        }
      },
    );
    _events = events;
    try {
      final value = await platform.open();
      if (operation != _epoch || !_current()) {
        try {
          await platform.close(value.id);
        } catch (_) {
          // Native lifecycle ownership remains authoritative.
        }
        return;
      }
      _session = value;
      if (earlyError) {
        _nativeFailure(operation);
      } else if (earlyEvent case final event?) {
        _nativeEvent(operation, event);
      }
    } on PersonalCameraException catch (error) {
      if (operation == _epoch && _current()) failure = error.failure;
    } catch (_) {
      if (operation == _epoch && _current()) {
        failure = PersonalCameraFailure.unavailable;
      }
    } finally {
      if (operation == _epoch && !_disposed) {
        opening = false;
        if (_session == null) {
          await events.cancel();
          if (identical(_events, events)) _events = null;
        }
        notifyListeners();
      }
    }
  }

  void _nativeEvent(int operation, PersonalCameraEvent event) {
    final current = _session;
    if (operation != _epoch ||
        current == null ||
        event.sessionId != current.id) {
      return;
    }
    failure = switch (event.reason) {
      'permissionDenied' => PersonalCameraFailure.permissionDenied,
      'noFrontCamera' => PersonalCameraFailure.noFrontCamera,
      'cameraBusy' => PersonalCameraFailure.cameraBusy,
      'batteryCritical' => PersonalCameraFailure.batteryCritical,
      'thermalCritical' => PersonalCameraFailure.thermalCritical,
      _ => null,
    };
    _session = null;
    opening = false;
    _epoch++;
    unawaited(_events?.cancel());
    _events = null;
    notifyListeners();
  }

  void _nativeFailure(int operation) {
    if (operation != _epoch || _session == null) return;
    failure = PersonalCameraFailure.unavailable;
    unawaited(close(keepFailure: true));
  }

  Future<void> close({bool keepFailure = false}) async {
    final current = _session;
    if (current == null) {
      _epoch++;
      opening = false;
      if (!keepFailure) failure = null;
      final subscription = _events;
      _events = null;
      await subscription?.cancel();
      if (!_disposed) notifyListeners();
      return;
    }
    _session = null;
    _epoch++;
    opening = false;
    if (!keepFailure) failure = null;
    final subscription = _events;
    _events = null;
    if (!_disposed) notifyListeners();
    final closing = () async {
      try {
        await subscription?.cancel();
        await platform.close(current.id);
        return true;
      } catch (_) {
        return false;
      }
    }();
    _closing = closing;
    final closed = await closing.timeout(closeTimeout, onTimeout: () => false);
    if (identical(_closing, closing)) {
      if (closed) {
        _closing = null;
      } else if (!_disposed) {
        failure = PersonalCameraFailure.unavailable;
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> retire() async {
    _epoch++;
    await close();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    final current = _session;
    _session = null;
    unawaited(_events?.cancel());
    _events = null;
    if (current != null) unawaited(platform.close(current.id));
    super.dispose();
  }
}
