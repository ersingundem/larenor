import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/larenor_server_api.dart';

final class _DestinationOperation {
  _DestinationOperation(this.id);

  final String id;
  final Completer<void> _cancelled = Completer<void>();

  Future<void> get cancelled => _cancelled.future;
  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Opens an OS-owned Android document and exposes only bounded append calls.
class ServerCoreBackupFileAccess {
  ServerCoreBackupFileAccess({
    MethodChannel? channel,
    bool? isAndroid,
    String Function()? operationIdFactory,
    this.platformTimeout = const Duration(seconds: 20),
  }) : _channel = channel ?? const MethodChannel(channelName),
       _isAndroid =
           isAndroid ?? defaultTargetPlatform == TargetPlatform.android,
       _operationIdFactory = operationIdFactory ?? _randomId;

  static const channelName = 'com.ersingundem.larenor/core_backup_destination';
  static const maxChunkBytes = 64 * 1024;
  static const maxBytes = LarenorServerApi.maxCoreBackupBytes;
  final MethodChannel _channel;
  final bool _isAndroid;
  final String Function() _operationIdFactory;
  final Duration platformTimeout;
  _DestinationOperation? _activeOperation;
  bool get hasPendingOperation => _activeOperation != null;

  ServerCoreBackupFileAccess scoped() => ServerCoreBackupFileAccess(
    channel: _channel,
    isAndroid: _isAndroid,
    operationIdFactory: _operationIdFactory,
    platformTimeout: platformTimeout,
  );

  Future<LarenorBinaryDestination?> open(String filename) async {
    if (!_isAndroid || filename != 'larenor-core-backup.larenor-core') {
      return null;
    }
    if (_activeOperation != null) {
      throw StateError('Backup destination is busy');
    }
    final operation = _DestinationOperation(_operationIdFactory());
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(operation.id)) {
      throw StateError('Backup destination is busy');
    }
    _activeOperation = operation;
    try {
      final raw = await Future.any<Map<String, dynamic>?>([
        _channel.invokeMapMethod<String, dynamic>('open', {
          'sessionId': operation.id,
          'fileName': filename,
          'mimeType': 'application/vnd.larenor.core-backup',
        }),
        operation.cancelled.then((_) => null),
      ]).timeout(const Duration(minutes: 5));
      if (!identical(_activeOperation, operation) || operation.isCancelled) {
        return null;
      }
      final handle = raw?['handle'];
      if (handle is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(handle)) {
        if (raw == null) {
          if (identical(_activeOperation, operation)) _activeOperation = null;
          return null;
        }
        throw const FormatException('Invalid backup destination');
      }
      final destination = _AndroidBackupDestination(
        _channel,
        operation.id,
        handle,
        platformTimeout,
        () {
          if (identical(_activeOperation, operation)) _activeOperation = null;
        },
      );
      if (!identical(_activeOperation, operation) || operation.isCancelled) {
        await destination.cancel();
        return null;
      }
      return destination;
    } on PlatformException catch (error) {
      if (identical(_activeOperation, operation)) _activeOperation = null;
      if (operation.isCancelled) return null;
      await _cancelOperation(operation.id);
      if (error.code == 'cancelled' || error.code == 'expired') return null;
      rethrow;
    } catch (_) {
      if (identical(_activeOperation, operation)) _activeOperation = null;
      if (operation.isCancelled) return null;
      await _cancelOperation(operation.id);
      rethrow;
    }
  }

  Future<void> cancelPending() async {
    final operation = _activeOperation;
    if (operation == null) return;
    _activeOperation = null;
    operation.cancel();
    await _cancelOperation(operation.id);
  }

  Future<void> _cancelOperation(String operation) async {
    try {
      await _channel
          .invokeMethod<void>('cancel', {'sessionId': operation})
          .timeout(platformTimeout);
    } catch (_) {
      // Activity teardown may already have closed and deleted the destination.
    }
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
      growable: false,
    ).join();
  }
}

final class _AndroidBackupDestination implements LarenorBinaryDestination {
  _AndroidBackupDestination(
    this._channel,
    this._sessionId,
    this._handle,
    this._timeout,
    this._onClosed,
  );
  final MethodChannel _channel;
  final String _sessionId;
  final String _handle;
  final Duration _timeout;
  final VoidCallback _onClosed;
  bool _closed = false;

  Map<String, Object> get _identity => {
    'sessionId': _sessionId,
    'handle': _handle,
  };

  @override
  Future<void> add(Uint8List bytes) async {
    if (_closed ||
        bytes.isEmpty ||
        bytes.length > ServerCoreBackupFileAccess.maxChunkBytes) {
      throw ArgumentError.value(bytes.length, 'bytes');
    }
    await _channel
        .invokeMethod<void>('append', {..._identity, 'bytes': bytes})
        .timeout(_timeout);
    if (_closed) throw StateError('Backup destination is closed');
  }

  @override
  Future<Uri> commit({required int byteLength, required String sha256}) async {
    if (_closed ||
        byteLength < 1 ||
        byteLength > ServerCoreBackupFileAccess.maxBytes ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw ArgumentError('Invalid backup commit proof');
    }
    final raw = await _channel
        .invokeMethod<String>('commit', {
          ..._identity,
          'byteLength': byteLength,
          'sha256': sha256,
        })
        .timeout(_timeout);
    if (_closed) throw StateError('Backup destination is closed');
    final uri = raw == null ? null : Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'content' || uri.host.isEmpty) {
      throw const FormatException('Invalid backup destination');
    }
    _closed = true;
    _onClosed();
    return uri;
  }

  @override
  Future<void> cancel() async {
    if (_closed) return;
    _closed = true;
    _onClosed();
    try {
      await _channel.invokeMethod<void>('cancel', _identity).timeout(_timeout);
    } catch (_) {
      // Native lifecycle teardown already owns partial-document cleanup.
    }
  }
}

final serverCoreBackupFileAccessProvider = Provider<ServerCoreBackupFileAccess>(
  (ref) => ServerCoreBackupFileAccess(),
);
