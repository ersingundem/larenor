import 'package:flutter/foundation.dart';

/// Bounded metadata produced after Android has scanned and closed a selected
/// Core backup source. It is inspection evidence only, never restore authority.
@immutable
final class ServerCoreBackupSourceInspection {
  const ServerCoreBackupSourceInspection({
    required this.byteLength,
    required this.sha256,
  });

  final int byteLength;
  final String sha256;

  /// A successful native inspection has already matched the fixed envelope
  /// magic. The source is closed before this value crosses into Dart.
  bool get magicVerified => true;
}
