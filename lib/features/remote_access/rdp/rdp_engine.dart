import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/services.dart';

import '../data/remote_profiles.dart';
import 'rdp_models.dart';

abstract interface class RdpChannel {
  Future<void> get done;
  void pointer(RdpPointerEvent event);
  void key(RdpKeyEvent event);
  void text(String value);
  void resize(RdpDisplaySpec display);
  void close();
}

class RdpFrame {
  const RdpFrame({
    required this.sequence,
    required this.width,
    required this.height,
    required this.stride,
    required this.dpi,
    required this.bgra,
  });
  final int sequence, width, height, stride, dpi;
  final Uint8List bgra;
}

abstract interface class RdpFrameChannel implements RdpChannel {
  Stream<RdpFrame> get frames;
  Future<void> acknowledgeFrame(int sequence);
}

abstract interface class RdpEngine {
  Future<RdpCapabilities> capabilities({required bool Function() isCurrent});
  Future<RdpPeerSecurity> inspect(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  });
  Future<RdpChannel> open(
    RdpSessionRequest request, {
    required RdpCredential? credential,
    required bool Function() isCurrent,
  });
  void close();
}

/// Product default until a reviewed native engine is packaged. It performs no
/// DNS lookup or socket operation and exposes no pretend session capability.
class UnsupportedRdpEngine implements RdpEngine {
  @override
  Future<RdpCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw const RdpFailure('retired');
    return RdpCapabilities.fromJson(const {
      'schemaVersion': 1,
      'availability': 'unavailable',
      'engineRevision': null,
      'security': {'tls': false, 'certificatePinning': false, 'nla': false},
      'display': {
        'dynamicResolution': false,
        'externalDisplay': false,
        'maxWidth': 0,
        'maxHeight': 0,
        'maxDpi': 0,
      },
      'input': {'touchpad': false, 'keyboard': false, 'ime': false},
      'channels': {'clipboard': false, 'audio': false, 'files': false},
    });
  }

  @override
  Future<RdpPeerSecurity> inspect(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) => throw const RdpFailure('engine_unavailable');
  @override
  Future<RdpChannel> open(
    RdpSessionRequest request, {
    required RdpCredential? credential,
    required bool Function() isCurrent,
  }) => throw const RdpFailure('engine_unavailable');
  @override
  void close() {}
}

/// Android product engine. The native side remains unavailable unless the
/// reviewed FreeRDP AAR and its exact receipt were packaged into this APK.
class RdpMethodChannelEngine implements RdpEngine {
  RdpMethodChannelEngine({
    MethodChannel? methods,
    EventChannel? events,
    Random? random,
    bool? isAndroid,
  }) : _methods = methods ?? const MethodChannel(_methodsName),
       _events = events ?? const EventChannel(_eventsName),
       _random = random ?? Random.secure(),
       _isAndroid = isAndroid ?? Platform.isAndroid;

  static const _methodsName = 'com.ersingundem.larenor/rdp-native';
  static const _eventsName = 'com.ersingundem.larenor/rdp-native-events';
  final MethodChannel _methods;
  final EventChannel _events;
  final Random _random;
  final bool _isAndroid;
  _RdpMethodChannel? _active;
  bool _closed = false;

  @override
  Future<RdpCapabilities> capabilities({
    required bool Function() isCurrent,
  }) async {
    if (_closed || !isCurrent() || !_isAndroid) {
      return UnsupportedRdpEngine().capabilities(isCurrent: isCurrent);
    }
    try {
      final raw = await _methods.invokeMethod<Object?>('capabilities');
      if (!isCurrent() || _closed) throw const RdpFailure('retired');
      if (raw == null) {
        return await UnsupportedRdpEngine().capabilities(isCurrent: isCurrent);
      }
      return RdpCapabilities.fromJson(raw);
    } on MissingPluginException {
      return await UnsupportedRdpEngine().capabilities(isCurrent: isCurrent);
    } on PlatformException catch (error) {
      if (error.code == 'channel-error') {
        return await UnsupportedRdpEngine().capabilities(isCurrent: isCurrent);
      }
      throw RdpFailure(_failure(error.code));
    }
  }

  @override
  Future<RdpPeerSecurity> inspect(
    RemoteProfile profile, {
    required bool Function() isCurrent,
  }) async {
    if (_closed || !isCurrent()) throw const RdpFailure('retired');
    try {
      final raw = await _methods.invokeMethod<Object?>('inspect', {
        'targetHost': profile.host,
        'targetPort': profile.port,
        'username': profile.username,
      });
      if (!isCurrent() || _closed) {
        await _cancel();
        throw const RdpFailure('retired');
      }
      final value = _strict(raw, {
        'tls',
        'requiresNla',
        'certificateFingerprint',
      });
      if (value['tls'] is! bool ||
          value['requiresNla'] is! bool ||
          value['certificateFingerprint'] is! String) {
        throw const RdpFailure('invalid_response');
      }
      return RdpPeerSecurity(
        tls: value['tls'] as bool,
        requiresNla: value['requiresNla'] as bool,
        certificate: RdpCertificatePin(
          algorithm: 'spki-sha256',
          fingerprint: value['certificateFingerprint'] as String,
        )..validate(),
      );
    } on PlatformException catch (error) {
      throw RdpFailure(_failure(error.code));
    }
  }

  @override
  Future<RdpChannel> open(
    RdpSessionRequest request, {
    required RdpCredential? credential,
    required bool Function() isCurrent,
  }) async {
    if (_closed || !isCurrent()) throw const RdpFailure('retired');
    if (credential == null) throw const RdpFailure('invalid_credential');
    final existing = _active;
    if (existing != null) throw const RdpFailure('busy');
    final requestId = _uuid();
    final channel = _RdpMethodChannel(
      methods: _methods,
      events: _events,
      requestId: requestId,
      isCurrent: () => !_closed && isCurrent(),
      onClosed: () => _active = null,
    );
    _active = channel;
    try {
      await channel.open(request, credential);
      if (!isCurrent() || _closed) {
        channel.close();
        throw const RdpFailure('retired');
      }
      return channel;
    } catch (_) {
      channel.close();
      if (identical(_active, channel)) _active = null;
      rethrow;
    }
  }

  String _uuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final h = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<void> _cancel() async {
    try {
      await _methods.invokeMethod<void>('cancel');
    } catch (_) {}
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _active?.close();
    _active = null;
    unawaited(_cancel());
  }
}

class _RdpMethodChannel implements RdpFrameChannel {
  _RdpMethodChannel({
    required this.methods,
    required this.events,
    required this.requestId,
    required this.isCurrent,
    required this.onClosed,
  });
  final MethodChannel methods;
  final EventChannel events;
  final String requestId;
  final bool Function() isCurrent;
  final VoidCallback onClosed;
  final _done = Completer<void>();
  final _frames = StreamController<RdpFrame>.broadcast(sync: true);
  StreamSubscription<Object?>? _subscription;
  int _inputSequence = 0;
  bool _closed = false;

  @override
  Future<void> get done => _done.future;
  @override
  Stream<RdpFrame> get frames => _frames.stream;

  Future<void> open(RdpSessionRequest request, RdpCredential credential) async {
    _subscription = events
        .receiveBroadcastStream(requestId)
        .listen(
          _event,
          onError: (Object error) => _finish(error),
          onDone: _finish,
          cancelOnError: true,
        );
    final password = Uint8List.fromList(utf8.encode(credential.password));
    final gateway = Uint8List.fromList(utf8.encode(credential.gatewayPassword));
    try {
      await methods.invokeMethod<void>('activate', {'requestId': requestId});
      await methods.invokeMethod<void>('open', {
        'request': _request(request),
        'requestId': requestId,
        'password': password,
        'gatewayPassword': gateway,
      });
    } on PlatformException catch (error) {
      throw RdpFailure(_failure(error.code));
    } finally {
      password.fillRange(0, password.length, 0);
      gateway.fillRange(0, gateway.length, 0);
    }
  }

  Map<String, Object?> _request(RdpSessionRequest value) => {
    'schemaVersion': 1,
    'requestId': requestId,
    'targetHost': value.profile.host,
    'targetPort': value.profile.port,
    'username': value.profile.username,
    'domain': value.settings.domain,
    'gateway': value.settings.gatewayHost == null
        ? null
        : {
            'host': value.settings.gatewayHost,
            'port': value.settings.gatewayPort,
            'username': value.settings.gatewayUsername,
          },
    'certificateFingerprint': value.certificateFingerprint,
    'requiresNla': true,
    'display': {
      'width': value.display.width,
      'height': value.display.height,
      'dpi': value.display.dpi,
      'externalDisplay': value.display.externalDisplay,
      'dynamicResize': true,
    },
    'keyboardLayout': value.settings.keyboardLayout.name,
    'clipboardMode': value.settings.clipboardMode.name,
    'audio': value.channels.audio,
    'files': value.channels.files,
  };

  void _event(Object? raw) {
    if (_closed || !isCurrent()) {
      close();
      return;
    }
    try {
      final value = _strict(raw, {'requestId', 'kind', 'payload'});
      if (value['requestId'] != requestId || value['kind'] is! String) {
        throw const RdpFailure('invalid_response');
      }
      if (value['kind'] == 'disconnected') {
        _finish();
      } else if (value['kind'] == 'frame') {
        final frame = _strict(value['payload'], {
          'sequence',
          'width',
          'height',
          'stride',
          'dpi',
          'pixels',
        });
        final sequence = frame['sequence'],
            width = frame['width'],
            height = frame['height'],
            stride = frame['stride'],
            dpi = frame['dpi'],
            pixels = frame['pixels'];
        if (sequence is! int ||
            sequence <= 0 ||
            width is! int ||
            width < 640 ||
            height is! int ||
            height < 480 ||
            stride is! int ||
            stride != width * 4 ||
            dpi is! int ||
            dpi < 72 ||
            pixels is! Uint8List) {
          throw const RdpFailure('invalid_response');
        }
        final parsedWidth = width;
        final parsedHeight = height;
        final parsedStride = stride;
        final parsedDpi = dpi;
        if (pixels.length != parsedStride * parsedHeight ||
            pixels.length > 64 * 1024 * 1024) {
          throw const RdpFailure('invalid_response');
        }
        _frames.add(
          RdpFrame(
            sequence: sequence,
            width: parsedWidth,
            height: parsedHeight,
            stride: parsedStride,
            dpi: parsedDpi,
            bgra: pixels,
          ),
        );
      } else {
        throw const RdpFailure('invalid_response');
      }
    } catch (error) {
      _finish(error);
      close();
    }
  }

  Future<void> _invoke(
    String method,
    Map<String, Object?> event, {
    bool consumeInputSequence = true,
  }) async {
    if (_closed || !isCurrent()) return;
    final sequence = consumeInputSequence ? ++_inputSequence : _inputSequence;
    try {
      await methods.invokeMethod<void>(method, {
        'requestId': requestId,
        'sequence': sequence,
        ...event,
      });
    } catch (_) {
      close();
    }
  }

  @override
  void pointer(RdpPointerEvent event) => unawaited(
    _invoke('input', {
      'kind': 'pointer',
      'x': event.x,
      'y': event.y,
      'buttons': event.buttons,
    }),
  );
  @override
  void key(RdpKeyEvent event) => unawaited(
    _invoke('input', {
      'kind': 'key',
      'physicalKey': event.physicalKey,
      'down': event.down,
    }),
  );
  @override
  void text(String value) {
    if (!_validImeText(value)) return;
    unawaited(_invoke('input', {'kind': 'ime', 'text': value}));
  }

  @override
  void resize(RdpDisplaySpec display) => unawaited(
    _invoke('resize', {
      'display': {
        'width': display.width,
        'height': display.height,
        'dpi': display.dpi,
        'externalDisplay': display.externalDisplay,
        'dynamicResize': true,
      },
    }),
  );
  @override
  Future<void> acknowledgeFrame(int sequence) async {
    if (_closed || !isCurrent()) return;
    try {
      await methods.invokeMethod<void>('ackFrame', {
        'requestId': requestId,
        'frameSequence': sequence,
      });
    } catch (_) {
      close();
    }
  }

  void _finish([Object? error]) {
    if (!_done.isCompleted) {
      error == null ? _done.complete() : _done.completeError(error);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(
      methods
          .invokeMethod<void>('cancel', {'requestId': requestId})
          .catchError((_) {}),
    );
    unawaited(_frames.close());
    _finish();
    onClosed();
  }
}

bool _validImeText(String value) =>
    value.isNotEmpty &&
    !value.contains('\u0000') &&
    utf8.encode(value).length <= 4096;

Map<Object?, Object?> _strict(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    throw const RdpFailure('invalid_response');
  }
  return raw;
}

String _failure(String code) => switch (code) {
  'engineUnavailable' => 'engine_unavailable',
  'tlsRequired' => 'tls_required',
  'certificatePinningRequired' => 'certificate_changed',
  'nlaUnavailable' => 'nla_unsupported',
  'invalidSecrets' => 'invalid_credential',
  'cancelled' || 'staleSession' || 'foregroundRequired' => 'retired',
  'timedOut' => 'timed_out',
  'busy' => 'busy',
  _ => 'connection_failed',
};
