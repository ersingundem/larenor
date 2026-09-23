import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
final class ServerCoreBackupSourceInspection {
  const ServerCoreBackupSourceInspection({
    required this.byteLength,
    required this.sha256,
  });

  final int byteLength;
  final String sha256;
}

/// Asks Android's document picker to inspect an encrypted Core backup.
///
/// The native side scans the source in bounded chunks and closes it before
/// returning. URI, display name, and bundle bytes never cross the channel.
class ServerCoreBackupSourceAccess {
  ServerCoreBackupSourceAccess({
    MethodChannel? channel,
    bool? isAndroid,
    String Function()? operationIdFactory,
    this.platformTimeout = const Duration(seconds: 20),
    this.inspectTimeout = const Duration(minutes: 5),
  }) : _channel = channel ?? const MethodChannel(channelName),
       _isAndroid =
           isAndroid ?? defaultTargetPlatform == TargetPlatform.android,
       _operationIdFactory = operationIdFactory ?? _randomId;

  static const channelName = 'com.ersingundem.larenor/core_backup_source';
  static const maxBytes = 424 * 1024 * 1024;
  static const minEnvelopeBytes = 65;

  final MethodChannel _channel;
  final bool _isAndroid;
  final String Function() _operationIdFactory;
  final Duration platformTimeout;
  final Duration inspectTimeout;
  String? _activeOperation;

  bool get hasPendingOperation => _activeOperation != null;

  ServerCoreBackupSourceAccess scoped() => ServerCoreBackupSourceAccess(
    channel: _channel,
    isAndroid: _isAndroid,
    platformTimeout: platformTimeout,
    inspectTimeout: inspectTimeout,
  );

  Future<ServerCoreBackupSourceInspection?> inspect() async {
    if (!_isAndroid) return null;
    final operation = _operationIdFactory();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(operation) ||
        _activeOperation != null) {
      throw StateError('Backup source is busy');
    }
    _activeOperation = operation;
    try {
      final raw = await _channel
          .invokeMapMethod<String, dynamic>('inspect', {
            'sessionId': operation,
            'mimeType': 'application/vnd.larenor.core-backup',
          })
          .timeout(inspectTimeout);
      if (_activeOperation != operation) return null;
      _activeOperation = null;
      if (raw == null) return null;
      if (raw.keys.toSet().difference({'byteLength', 'sha256'}).isNotEmpty ||
          raw.length != 2) {
        throw const FormatException('Invalid backup source proof');
      }
      final byteLength = raw['byteLength'];
      final sha256 = raw['sha256'];
      if (byteLength is! int ||
          byteLength < minEnvelopeBytes ||
          byteLength > maxBytes ||
          sha256 is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
        throw const FormatException('Invalid backup source proof');
      }
      return ServerCoreBackupSourceInspection(
        byteLength: byteLength,
        sha256: sha256,
      );
    } on PlatformException catch (error) {
      if (_activeOperation == operation) _activeOperation = null;
      await _cancelOperation(operation);
      if (error.code == 'cancelled' || error.code == 'expired') return null;
      rethrow;
    } catch (_) {
      if (_activeOperation == operation) _activeOperation = null;
      await _cancelOperation(operation);
      rethrow;
    }
  }

  Future<void> cancelPending() async {
    final operation = _activeOperation;
    if (operation == null) return;
    _activeOperation = null;
    await _cancelOperation(operation);
  }

  Future<void> _cancelOperation(String operation) async {
    try {
      await _channel
          .invokeMethod<void>('cancel', {'sessionId': operation})
          .timeout(platformTimeout);
    } catch (_) {
      // Lifecycle teardown may already own and close the native source.
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

final serverCoreBackupSourceAccessProvider =
    Provider<ServerCoreBackupSourceAccess>(
      (ref) => ServerCoreBackupSourceAccess(),
    );
