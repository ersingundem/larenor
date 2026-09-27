import '../../server/domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<Object?, Object?> _object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

String _hex(Object? raw, int length) {
  if (raw is! String ||
      raw.length != length ||
      !RegExp('^[0-9a-f]{$length}\$').hasMatch(raw)) {
    _invalid();
  }
  return raw;
}

/// A fresh, server-authenticated view of the whole Core audit journal.
final class CoreAuditVerification {
  const CoreAuditVerification._({
    required this.context,
    required this.chainId,
    required this.sequence,
    required this.headHash,
    required this.checkpoint,
    required this.comparedCheckpoint,
  });

  static const maximumSequence = 30000;

  final ServerContext context;
  final String chainId, headHash, checkpoint;
  final int sequence;
  final bool comparedCheckpoint;
  bool get verified => true;
  bool get causalityVerified => false;

  factory CoreAuditVerification.fromJson(
    Object? raw, {
    required ServerContext expectedContext,
    required bool expectedComparison,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'scope',
      'chainId',
      'sequence',
      'headHash',
      'checkpoint',
      'verified',
      'comparedCheckpoint',
      'causalityVerified',
    });
    if (value['schemaVersion'] is! int || value['schemaVersion'] != 1) {
      _invalid();
    }
    final context = ServerContext.fromJson(value['scope']);
    final sequence = value['sequence'];
    final checkpoint = value['checkpoint'];
    if (context != expectedContext ||
        sequence is! int ||
        sequence < 0 ||
        sequence > maximumSequence ||
        checkpoint is! String ||
        checkpoint.isEmpty ||
        checkpoint.length > 512 ||
        checkpoint.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e) ||
        value['verified'] != true ||
        value['comparedCheckpoint'] != expectedComparison ||
        value['causalityVerified'] != false) {
      _invalid();
    }
    return CoreAuditVerification._(
      context: context,
      chainId: _hex(value['chainId'], 32),
      sequence: sequence,
      headHash: _hex(value['headHash'], 64),
      checkpoint: checkpoint,
      comparedCheckpoint: expectedComparison,
    );
  }
}
