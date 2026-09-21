import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../server/domain/server_models.dart';
import '../domain/local_notification_models.dart';

enum AndroidNotificationPermission {
  unsupported,
  notRequested,
  denied,
  granted,
}

final class AndroidNotificationStatus {
  const AndroidNotificationStatus({
    required this.permission,
    required this.channelEnabled,
    required this.recoveryRequired,
    required this.batteryOptimizationExempt,
    required this.deliveryMode,
  });
  final AndroidNotificationPermission permission;
  final bool channelEnabled, recoveryRequired, batteryOptimizationExempt;
  final String deliveryMode;
  bool get canPresent =>
      permission == AndroidNotificationPermission.granted && channelEnabled;
}

final class LocalNotificationTap {
  const LocalNotificationTap({
    required this.bindingId,
    required this.subscriptionRevision,
    required this.eventId,
    required this.sequence,
  });
  final String bindingId, eventId;
  final int subscriptionRevision, sequence;

  factory LocalNotificationTap.fromJson(Object? raw) {
    const keys = {
      'schemaVersion',
      'bindingId',
      'subscriptionRevision',
      'eventId',
      'sequence',
    };
    if (raw is! Map ||
        raw.length != keys.length ||
        raw.keys.any((key) => !keys.contains(key)) ||
        raw['schemaVersion'] != 1 ||
        raw['bindingId'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['bindingId']) ||
        raw['eventId'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(raw['eventId']) ||
        raw['subscriptionRevision'] is! int ||
        raw['subscriptionRevision'] < 1 ||
        raw['sequence'] is! int ||
        raw['sequence'] < 1) {
      throw const LarenorServerException('invalid_response');
    }
    return LocalNotificationTap(
      bindingId: raw['bindingId'],
      subscriptionRevision: raw['subscriptionRevision'],
      eventId: raw['eventId'],
      sequence: raw['sequence'],
    );
  }
}

abstract interface class LocalNotificationPlatform {
  Stream<LocalNotificationTap> get taps;
  Future<AndroidNotificationStatus> probe({required bool Function() current});
  Future<AndroidNotificationStatus> requestPermission({
    required bool Function() current,
  });
  Future<AndroidNotificationStatus> reconcile({
    required ServerSession session,
    required LocalNotificationSubscription subscription,
    required List<LocalNotificationEvent> events,
    required bool Function() current,
  });
  Future<void> openNotificationSettings({required bool Function() current});
  Future<void> openPowerSettings({required bool Function() current});
}

final class AndroidLocalNotificationPlatform
    implements LocalNotificationPlatform {
  AndroidLocalNotificationPlatform({
    MethodChannel? methods,
    EventChannel? events,
    bool? supported,
  }) : _methods =
           methods ??
           const MethodChannel('com.ersingundem.larenor/local_notifications'),
       _events =
           events ??
           const EventChannel(
             'com.ersingundem.larenor/local_notification_taps',
           ),
       _supported = supported ?? Platform.isAndroid;

  final MethodChannel _methods;
  final EventChannel _events;
  final bool _supported;
  Stream<LocalNotificationTap>? _taps;

  static String bindingId(ServerSession session) {
    final context = session.context!;
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([context.coreId, context.homeId, session.user.id]),
          ),
        )
        .toString();
  }

  Never _failure([String code = 'platform_unavailable']) =>
      throw LarenorServerException(code);

  T _current<T>(T value, bool Function() current) {
    try {
      if (current()) return value;
    } catch (_) {}
    _failure('cancelled');
  }

  @override
  Stream<LocalNotificationTap> get taps {
    if (!_supported) return const Stream.empty();
    return _taps ??= _events.receiveBroadcastStream().map(
      LocalNotificationTap.fromJson,
    );
  }

  AndroidNotificationStatus _status(Object? raw) {
    if (raw is! Map) _failure('invalid_response');
    const keys = {
      'schemaVersion',
      'supported',
      'permission',
      'channelVersion',
      'channelEnabled',
      'bindingId',
      'subscriptionRevision',
      'lastSequence',
      'recoveryRequired',
      'batteryOptimizationExempt',
      'deliveryMode',
    };
    // The native map has eleven fields; count and exact keys both fail closed.
    if (raw.length != keys.length ||
        raw.keys.any((key) => !keys.contains(key))) {
      _failure('invalid_response');
    }
    final permission = switch (raw['permission']) {
      'notRequested' => AndroidNotificationPermission.notRequested,
      'denied' => AndroidNotificationPermission.denied,
      'granted' => AndroidNotificationPermission.granted,
      _ => _failure('invalid_response'),
    };
    if (raw['schemaVersion'] != 1 ||
        raw['supported'] != true ||
        raw['channelVersion'] != 1 ||
        raw['channelEnabled'] is! bool ||
        raw['recoveryRequired'] is! bool ||
        raw['batteryOptimizationExempt'] is! bool ||
        raw['deliveryMode'] != 'foregroundPull' ||
        raw['subscriptionRevision'] is! int ||
        raw['subscriptionRevision'] < 0 ||
        raw['lastSequence'] is! int ||
        raw['lastSequence'] < 0 ||
        raw['bindingId'] != null &&
            (raw['bindingId'] is! String ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['bindingId']))) {
      _failure('invalid_response');
    }
    return AndroidNotificationStatus(
      permission: permission,
      channelEnabled: raw['channelEnabled'],
      recoveryRequired: raw['recoveryRequired'],
      batteryOptimizationExempt: raw['batteryOptimizationExempt'],
      deliveryMode: raw['deliveryMode'],
    );
  }

  Future<T> _invoke<T>(
    String method,
    Object? arguments,
    bool Function() current,
    T Function(Object?) parse,
  ) async {
    if (!_supported) return parse(null);
    _current(null, current);
    try {
      final raw = await _methods.invokeMethod<Object?>(method, arguments);
      final parsed = parse(raw);
      return await Future<T>.value(_current(parsed, current));
    } on PlatformException catch (error) {
      _current(null, current);
      _failure(error.code);
    } on MissingPluginException {
      _failure();
    }
  }

  static const _unsupported = AndroidNotificationStatus(
    permission: AndroidNotificationPermission.unsupported,
    channelEnabled: false,
    recoveryRequired: false,
    batteryOptimizationExempt: false,
    deliveryMode: 'unsupported',
  );

  @override
  Future<AndroidNotificationStatus> probe({required bool Function() current}) =>
      !_supported
      ? Future.value(_current(_unsupported, current))
      : _invoke('probe', null, current, _status);

  @override
  Future<AndroidNotificationStatus> requestPermission({
    required bool Function() current,
  }) => !_supported
      ? Future.value(_current(_unsupported, current))
      : _invoke('requestPermission', null, current, _status);

  @override
  Future<AndroidNotificationStatus> reconcile({
    required ServerSession session,
    required LocalNotificationSubscription subscription,
    required List<LocalNotificationEvent> events,
    required bool Function() current,
  }) async {
    if (!_supported) return _current(_unsupported, current);
    final binding = bindingId(session);
    final projected =
        events
            .where(
              (event) => event.readState == LocalNotificationReadState.unread,
            )
            .toList(growable: false)
          ..sort((left, right) => left.sequence.compareTo(right.sequence));
    final bounded = projected.length <= 50
        ? projected
        : projected.sublist(projected.length - 50);
    await _invoke(
      'bind',
      {
        'schemaVersion': 1,
        'bindingId': binding,
        'subscriptionId': subscription.id,
        'subscriptionRevision': subscription.revision,
      },
      current,
      _status,
    );
    return _invoke(
      'reconcile',
      {
        'schemaVersion': 1,
        'bindingId': binding,
        'subscriptionId': subscription.id,
        'subscriptionRevision': subscription.revision,
        'events': bounded
            .map(
              (event) => {
                'schemaVersion': 1,
                'id': event.id,
                'sequence': event.sequence,
                'sensitivity': event.sensitivity.name,
                'title': event.projection.title,
                'body': event.projection.body,
                'redacted': event.projection.redacted,
              },
            )
            .toList(growable: false),
      },
      current,
      _status,
    );
  }

  Future<void> _open(String method, bool Function() current) =>
      _invoke<void>(method, null, current, (_) {});
  @override
  Future<void> openNotificationSettings({required bool Function() current}) =>
      _open('openNotificationSettings', current);
  @override
  Future<void> openPowerSettings({required bool Function() current}) =>
      _open('openPowerSettings', current);
}
