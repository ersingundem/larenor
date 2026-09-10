import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:dartssh2/dartssh2.dart';

/// Fixed error codes only: parser exceptions may contain private key material.
class SshKeyParseException implements Exception {
  const SshKeyParseException._(this.code);
  final String code;

  @override
  String toString() => 'SshKeyParseException($code)';
}

/// Parses local private keys away from the UI isolate, with bounded lifetime.
///
/// The worker starts paused so cancellation during spawn can kill it before it
/// begins a potentially expensive, file-controlled OpenSSH bcrypt operation.
/// The task does not retain the PEM or passphrase after the worker is started.
class SshKeyParseTask {
  SshKeyParseTask(
    String pem, {
    String passphrase = '',
    Duration timeout = const Duration(seconds: 3),
  }) {
    if (!_fitsUtf8(pem, 32768) || !_fitsUtf8(passphrase, 1024)) {
      _fail('input_too_large');
    } else if (pem.trim().isEmpty) {
      _fail('invalid_key');
    } else if (timeout <= Duration.zero) {
      _fail('timed_out');
    } else {
      _timer = Timer(timeout, () => _fail('timed_out'));
      unawaited(_start(pem, passphrase));
    }
  }

  final _completion = Completer<List<SSHKeyPair>>();
  Isolate? _isolate;
  ReceivePort? _port;
  Timer? _timer;

  Future<List<SSHKeyPair>> get result => _completion.future;

  /// Idempotent; an already completed result is preserved.
  void cancel() => _fail('cancelled');

  Future<void> _start(String pem, String passphrase) async {
    final port = ReceivePort();
    _port = port;
    port.listen((message) {
      if (_completion.isCompleted) return;
      if (message is List<SSHKeyPair> && message.isNotEmpty) {
        _completion.complete(List<SSHKeyPair>.unmodifiable(message));
        _dispose();
      } else if (message == 'invalid_key' || message == 'unsupported_key') {
        _fail(message as String);
      } else {
        // Includes worker exit without a result and VM error notifications.
        _fail('parser_failed');
      }
    });

    try {
      final isolate = await Isolate.spawn(
        _parseKey,
        _KeyRequest(port.sendPort, pem, passphrase),
        paused: true,
        onError: port.sendPort,
        onExit: port.sendPort,
        errorsAreFatal: true,
        debugName: 'ssh-private-key-parser',
      );
      if (_completion.isCompleted) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
      isolate.resume(isolate.pauseCapability!);
    } catch (_) {
      _fail('parser_failed');
    }
  }

  void _fail(String code) {
    if (_completion.isCompleted) return;
    _completion.completeError(SshKeyParseException._(code));
    _dispose();
  }

  void _dispose() {
    _timer?.cancel();
    _timer = null;
    _port?.close();
    _port = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  static bool _fitsUtf8(String value, int maximum) =>
      value.length <= maximum && utf8.encode(value).length <= maximum;
}

class _KeyRequest {
  const _KeyRequest(this.reply, this.pem, this.passphrase);
  final SendPort reply;
  final String pem;
  final String passphrase;
}

// A top-level entry point avoids capturing the task, its ports or other state.
void _parseKey(_KeyRequest request) {
  try {
    final encrypted = SSHKeyPair.isEncryptedPem(request.pem);
    final keys = SSHKeyPair.fromPem(
      request.pem,
      encrypted && request.passphrase.isNotEmpty ? request.passphrase : null,
    );
    if (keys.isEmpty) {
      Isolate.exit(request.reply, 'invalid_key');
    }
    // These library key types contain transferable Dart data. Passing the
    // parsed keys avoids decrypting or parsing again in the caller's isolate.
    Isolate.exit(request.reply, keys);
  } on UnsupportedError {
    Isolate.exit(request.reply, 'unsupported_key');
  } catch (_) {
    Isolate.exit(request.reply, 'invalid_key');
  }
}
