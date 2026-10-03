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
  void relativePointer(RdpRelativePointerEvent event);
  void wheel(RdpWheelEvent event);
  void key(RdpKeyEvent event);
  void text(String value);
  Future<bool> sendClipboardText(String value);
  void resize(RdpDisplaySpec display);
  void close();
}

class RdpFrame {
  const RdpFrame({
    required this.sequence,
    required this.width,
    required this.height,
    required this.stride,
    required this.displayLayoutRevision,
    required this.bgra,
  });
  final int sequence, width, height, stride, displayLayoutRevision;
  RdpFrameGeometry get geometry => RdpFrameGeometry(
    frameSequence: sequence,
    width: width,
    height: height,
    displayLayoutRevision: displayLayoutRevision,
  );
  final Uint8List bgra;
}

abstract interface class RdpFrameChannel implements RdpChannel {
  Stream<RdpFrame> get frames;
  Future<bool> acknowledgeFrame(int sequence);
}

/// Authenticated, per-session input capability returned by native open.
abstract interface class RdpNegotiatedInputChannel implements RdpChannel {
  bool get supportsUnicodeInput;
  bool get supportsRelativePointer;
}

abstract interface class RdpEngine {
  Future<RdpCapabilities> capabilities({required bool Function() isCurrent});
  Future<RdpCertificateProbe> inspect(
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
    return RdpCapabilities.fromJson({
      "schemaVersion": 2,
      "availability": "unavailable",
      "engineRevision": null,
      "security": {
        "tls": false,
        "certificatePinning": false,
        "nla": false,
        "rdGateway": false,
      },
      "display": {
        "dynamicResolution": false,
        "externalDisplay": false,
        "maxWidth": 0,
        "maxHeight": 0,
        "desktopScaleFactorMin": 0,
        "desktopScaleFactorMax": 0,
        "deviceScaleFactors": [],
      },
      "input": {
        "keyboard": false,
        "ime": false,
        "absolutePointer": false,
        "relativePointerNegotiation": false,
        "verticalWheel": false,
      },
      "channels": {
        "clipboard": false,
        "audio": false,
        "files": false,
        "clipboardModes": [],
      },
    });
  }

  @override
  Future<RdpCertificateProbe> inspect(
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
  Future<RdpCertificateProbe> inspect(
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
      return RdpCertificateProbe(
        // Exact v1 wire keys are retained for compatibility. They describe
        // the certificate probe and fixed Client policy, not an authenticated
        // peer-selected security mode.
        tlsCertificateObserved: value['tls'] as bool,
        clientRequiresNla: value['requiresNla'] as bool,
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

class _RdpMethodChannel implements RdpFrameChannel, RdpNegotiatedInputChannel {
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
  int _lastFrameSequence = 0, _layoutRevision = 1;
  RdpFrame? _pendingFrame;
  RdpFrameGeometry? _acknowledgedGeometry;
  RdpDisplaySpec? _requestedDisplay;
  Future<bool>? _ackInFlight;
  bool _hasFrameConsumer = false;
  bool _closed = false;
  bool _clipboardEnabled = false;

  @override
  bool supportsUnicodeInput = false;
  @override
  bool supportsRelativePointer = false;

  @override
  Future<void> get done => _done.future;
  @override
  Stream<RdpFrame> get frames => Stream.multi((sink) {
    if (_closed || _hasFrameConsumer) {
      sink.addError(const RdpFailure('busy'));
      sink.close();
      return;
    }
    _hasFrameConsumer = true;
    final listener = _frames.stream.listen(
      sink.add,
      onError: sink.addError,
      onDone: sink.close,
    );
    final pending = _pendingFrame;
    if (pending != null) sink.add(pending);
    sink.onCancel = () {
      _hasFrameConsumer = false;
      return listener.cancel();
    };
  });

  Future<void> open(RdpSessionRequest request, RdpCredential credential) async {
    _requestedDisplay = request.display;
    _clipboardEnabled =
        request.settings.clipboardMode == RdpClipboardMode.clientToRemote &&
        request.channels.clipboard;
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
      final response = await methods.invokeMethod<Object?>('open', {
        'schemaVersion': 2,
        'request': _request(request),
        'requestId': requestId,
        'password': password,
        'gatewayPassword': gateway,
      });
      final parsed = _strict(response, {
        'schemaVersion',
        'unicodeTextInput',
        'relativePointer',
      });
      if (parsed['schemaVersion'] != 2 ||
          parsed['unicodeTextInput'] is! bool ||
          parsed['relativePointer'] is! bool) {
        throw const RdpFailure('invalid_response');
      }
      supportsUnicodeInput = parsed['unicodeTextInput']! as bool;
      supportsRelativePointer = parsed['relativePointer']! as bool;
    } on PlatformException catch (error) {
      throw RdpFailure(_failure(error.code));
    } finally {
      password.fillRange(0, password.length, 0);
      gateway.fillRange(0, gateway.length, 0);
    }
  }

  Map<String, Object?> _request(RdpSessionRequest value) => {
    'schemaVersion': 2,
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
    'display': value.display.toChannel(),
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
          'schemaVersion',
          'sequence',
          'width',
          'height',
          'stride',
          'displayLayoutRevision',
          'pixels',
        });
        final sequence = frame['sequence'],
            width = frame['width'],
            height = frame['height'],
            stride = frame['stride'],
            revision = frame['displayLayoutRevision'],
            pixels = frame['pixels'];
        if (frame['schemaVersion'] != 2 ||
            sequence is! int ||
            width is! int ||
            height is! int ||
            stride is! int ||
            revision is! int ||
            pixels is! Uint8List) {
          throw const RdpFailure('invalid_response');
        }
        final geometry = RdpFrameGeometry(
          frameSequence: sequence,
          width: width,
          height: height,
          displayLayoutRevision: revision,
        );
        if (!geometry.valid ||
            sequence != _lastFrameSequence + 1 ||
            _pendingFrame != null ||
            stride != width * 4 ||
            pixels.length != stride * height) {
          pixels.fillRange(0, pixels.length, 0);
          throw const RdpFailure('invalid_response');
        }
        final parsed = RdpFrame(
          sequence: sequence,
          width: width,
          height: height,
          stride: stride,
          displayLayoutRevision: revision,
          bgra: pixels,
        );
        _pendingFrame = parsed;
        _lastFrameSequence = sequence;
        _frames.add(parsed);
      } else {
        throw const RdpFailure('invalid_response');
      }
    } catch (error) {
      _finish(error);
      close();
    }
  }

  int? _nextInputSequence() {
    if (_inputSequence >= 9007199254740991) {
      close();
      return null;
    }
    return ++_inputSequence;
  }

  Future<void> _invoke(String method, Map<String, Object?> event) async {
    if (_closed || !isCurrent()) return;
    final sequence = _nextInputSequence();
    if (sequence == null) return;
    try {
      final response = await methods
          .invokeMethod<Object?>(method, {
            'schemaVersion': 2,
            'requestId': requestId,
            'sequence': sequence,
            ...event,
          })
          .timeout(const Duration(seconds: 5));
      final ignoredKey =
          method == 'input' && event['kind'] == 'key' && response == false;
      if (response != null && !ignoredKey) {
        throw const RdpFailure('invalid_response');
      }
    } catch (_) {
      close();
    }
  }

  bool _acceptsGeometry(RdpFrameGeometry geometry) =>
      !_closed &&
      isCurrent() &&
      geometry.valid &&
      geometry == _acknowledgedGeometry;

  @override
  void pointer(RdpPointerEvent event) {
    if (!event.valid || !_acceptsGeometry(event.geometry)) return;
    unawaited(
      _invoke('input', {
        'kind': 'absolutePointer',
        ...event.geometry.toChannel(),
        'x': event.x,
        'y': event.y,
        'buttons': event.buttons,
      }),
    );
  }

  @override
  void relativePointer(RdpRelativePointerEvent event) {
    if (!supportsRelativePointer ||
        !event.valid ||
        !_acceptsGeometry(event.geometry)) {
      return;
    }
    unawaited(
      _invoke('input', {
        'kind': 'relativePointer',
        ...event.geometry.toChannel(),
        'deltaX': event.deltaX,
        'deltaY': event.deltaY,
        'buttons': event.buttons,
      }),
    );
  }

  @override
  void wheel(RdpWheelEvent event) {
    if (!event.valid || !_acceptsGeometry(event.geometry)) return;
    unawaited(
      _invoke('input', {
        'kind': 'verticalWheel',
        ...event.geometry.toChannel(),
        'wheelDelta': event.wheelDelta,
      }),
    );
  }

  @override
  void key(RdpKeyEvent event) {
    if (!event.supported) return;
    unawaited(
      _invoke('input', {
        'kind': 'key',
        'physicalKey': event.physicalKey,
        'down': event.down,
      }),
    );
  }

  @override
  void text(String value) {
    if (!supportsUnicodeInput || !validRdpImeText(value)) return;
    unawaited(_invoke('input', {'kind': 'ime', 'text': value}));
  }

  @override
  Future<bool> sendClipboardText(String value) async {
    if (!_clipboardEnabled ||
        _closed ||
        !isCurrent() ||
        !validRdpClipboardText(value)) {
      return false;
    }
    final payload = Uint8List.fromList(utf8.encode(value));
    try {
      final sequence = _nextInputSequence();
      if (sequence == null) return false;
      final response = await methods
          .invokeMethod<Object?>('input', {
            'schemaVersion': 2,
            'requestId': requestId,
            'sequence': sequence,
            'kind': 'channel',
            'channel': 'clipboard',
            'payload': payload,
          })
          .timeout(const Duration(seconds: 5));
      if (response != null) throw const RdpFailure('invalid_response');
      return !_closed && isCurrent();
    } catch (_) {
      close();
      return false;
    } finally {
      payload.fillRange(0, payload.length, 0);
    }
  }

  @override
  void resize(RdpDisplaySpec display) {
    if (_closed ||
        !isCurrent() ||
        !display.valid ||
        display == _requestedDisplay) {
      return;
    }
    if (_layoutRevision >= 9007199254740991) {
      close();
      return;
    }
    _requestedDisplay = display;
    _layoutRevision++;
    _acknowledgedGeometry = null;
    unawaited(_invoke('resize', {'display': display.toChannel()}));
  }

  @override
  Future<bool> acknowledgeFrame(int sequence) async {
    final previous = _ackInFlight;
    if (previous != null) await previous;
    if (_closed || !isCurrent() || _pendingFrame?.sequence != sequence) {
      return false;
    }
    final pending = _pendingFrame!;
    final revision = _layoutRevision;
    // resumeFrames may publish the next unACKed frame before this reply. It
    // must not replace the geometry still displayed by the consumer.
    _pendingFrame = null;
    final completing = _ack(pending, revision);
    _ackInFlight = completing;
    try {
      return await completing;
    } finally {
      if (identical(_ackInFlight, completing)) _ackInFlight = null;
    }
  }

  Future<bool> _ack(RdpFrame pending, int revision) async {
    try {
      final reply = await methods
          .invokeMethod<Object?>('ackFrame', {
            'schemaVersion': 2,
            'requestId': requestId,
            'frameSequence': pending.sequence,
          })
          .timeout(const Duration(seconds: 5));
      if (reply != null) throw const RdpFailure('invalid_response');
      if (_closed || !isCurrent()) return false;
      final requested = _requestedDisplay!;
      _acknowledgedGeometry =
          revision == _layoutRevision &&
              pending.displayLayoutRevision == _layoutRevision &&
              pending.width == requested.width &&
              pending.height == requested.height
          ? pending.geometry
          : null;
      return true;
    } catch (_) {
      close();
      return false;
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
    final pending = _pendingFrame;
    pending?.bgra.fillRange(0, pending.bgra.length, 0);
    _pendingFrame = null;
    _acknowledgedGeometry = null;
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
