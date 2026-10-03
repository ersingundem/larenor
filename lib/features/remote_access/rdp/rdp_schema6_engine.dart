import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import 'rdp_models.dart';
import 'rdp_schema6_models.dart';
import 'rdp_security_store.dart';

abstract interface class RdpGatewayEnrollmentEngine {
  Future<RdpGatewayCertificateObservation> inspectGateway({
    required RdpGatewayEndpoint target,
    required RdpGatewayEndpoint gateway,
    required bool Function() isCurrent,
  });

  Future<RdpGatewayCertificateObservation> inspectTargetThroughGateway({
    required RdpGatewayEndpoint target,
    required RdpPinnedGatewayEndpoint gateway,
    required RdpOwnedSecretBuffer gatewayPassword,
    required bool Function() isCurrent,
  });

  void close();
}

/// Schema-6 transfer orchestration stays behind this port until the native
/// method names are frozen. No MethodChannel method is guessed here.
abstract interface class RdpSchema6TransferPort {
  Future<RdpTransferReceipt> prepare({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  });

  Future<RdpTransferReceipt> observe({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required String transferId,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  });

  /// Returns sealed only after native close has drained and mirror writes are
  /// impossible. Unknown is sticky and blocks every successor.
  Future<RdpTransferReceipt> drain({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required String transferId,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  });

  /// The only operation allowed to publish received mirror bytes through SAF.
  Future<RdpTransferReceipt> saveReceived({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required String transferId,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  });
}

/// Concrete schema-6 mirror/journal adapter. These methods are intentionally
/// separate from the schema-4 live session surface; Kotlin must bind every
/// call to the exact public owner pair and its private native owner.
final class RdpSchema6MethodChannelTransferPort
    implements RdpSchema6TransferPort {
  RdpSchema6MethodChannelTransferPort({
    MethodChannel? methods,
    Random? random,
    this.deadline = const Duration(seconds: 35),
  }) : _methods = methods ?? const MethodChannel(_methodsName),
       _random = random ?? Random.secure();

  static const _methodsName = 'com.ersingundem.larenor/rdp-native';
  final MethodChannel _methods;
  final Random _random;
  final Duration deadline;

  @override
  Future<RdpTransferReceipt> prepare({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  }) => _invoke(
    method: 'prepareFileTransfer',
    authority: authority,
    grant: grant,
    sessionOwner: sessionOwner,
    allowedStates: const {RdpTransferState.prepared},
    isCurrent: isCurrent,
  );

  @override
  Future<RdpTransferReceipt> observe({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required String transferId,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  }) => _invoke(
    method: 'fileTransferObservation',
    authority: authority,
    grant: grant,
    transferId: transferId,
    sessionOwner: sessionOwner,
    allowedStates: RdpTransferState.values.toSet(),
    isCurrent: isCurrent,
  );

  @override
  Future<RdpTransferReceipt> drain({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required String transferId,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  }) => _invoke(
    method: 'drainFileTransfer',
    authority: authority,
    grant: grant,
    transferId: transferId,
    sessionOwner: sessionOwner,
    allowedStates: const {RdpTransferState.sealed, RdpTransferState.unknown},
    isCurrent: isCurrent,
    cleanup: true,
  );

  @override
  Future<RdpTransferReceipt> saveReceived({
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required String transferId,
    required RdpSchema6SessionOwner sessionOwner,
    required bool Function() isCurrent,
  }) => _invoke(
    method: 'saveReceivedFiles',
    authority: authority,
    grant: grant,
    transferId: transferId,
    sessionOwner: sessionOwner,
    allowedStates: const {RdpTransferState.saved, RdpTransferState.unknown},
    isCurrent: isCurrent,
  );

  Future<RdpTransferReceipt> _invoke({
    required String method,
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required RdpSchema6SessionOwner sessionOwner,
    required Set<RdpTransferState> allowedStates,
    required bool Function() isCurrent,
    String? transferId,
    bool cleanup = false,
  }) async {
    if (!cleanup && !isCurrent()) throw const RdpFailure('retired');
    final requestId = _schema6Uuid(_random);
    try {
      final raw = await _methods
          .invokeMethod<Object?>(method, {
            'schemaVersion': 6,
            'requestId': requestId,
            'authority': authority.toWire(),
            'grantId': grant.id,
            'grantRevision': grant.revision,
            'transferId': ?transferId,
            'sessionRequestId': sessionOwner.requestId,
            'sessionRevision': sessionOwner.revision,
          })
          .timeout(deadline);
      if (!cleanup && !isCurrent()) throw const RdpFailure('retired');
      return RdpTransferReceipt.fromWire(
        raw,
        requestId: requestId,
        authority: authority,
        grant: grant,
        expectedTransferId: transferId,
        allowedStates: allowedStates,
      );
    } on TimeoutException {
      // A timed-out mutation is uncertain. Native journal observation is the
      // only legal recovery; never issue the operation again automatically.
      throw const RdpFailure('timed_out');
    } on PlatformException catch (error) {
      throw RdpFailure(_transferFailure(error.code));
    }
  }
}

final class RdpSchema6MethodChannelGatewayEngine
    implements RdpGatewayEnrollmentEngine {
  RdpSchema6MethodChannelGatewayEngine({
    MethodChannel? methods,
    Random? random,
    this.deadline = const Duration(seconds: 35),
  }) : _methods = methods ?? const MethodChannel(_methodsName),
       _random = random ?? Random.secure();

  static const _methodsName = 'com.ersingundem.larenor/rdp-native';
  final MethodChannel _methods;
  final Random _random;
  final Duration deadline;
  String? _activeRequestId;
  bool _closed = false;

  @override
  Future<RdpGatewayCertificateObservation> inspectGateway({
    required RdpGatewayEndpoint target,
    required RdpGatewayEndpoint gateway,
    required bool Function() isCurrent,
  }) => _inspect(
    method: 'inspectGateway',
    kind: RdpGatewayCertificateKind.gateway,
    arguments: {
      'target': target.toWire(includeDomain: false),
      'gateway': gateway.toWire(includeDomain: true),
    },
    isCurrent: isCurrent,
  );

  @override
  Future<RdpGatewayCertificateObservation> inspectTargetThroughGateway({
    required RdpGatewayEndpoint target,
    required RdpPinnedGatewayEndpoint gateway,
    required RdpOwnedSecretBuffer gatewayPassword,
    required bool Function() isCurrent,
  }) async {
    final password = gatewayPassword.take();
    try {
      return await _inspect(
        method: 'inspectTargetThroughGateway',
        kind: RdpGatewayCertificateKind.target,
        arguments: {
          'target': target.toWire(includeDomain: true),
          'gateway': gateway.toWire(),
          'gatewayPassword': password,
        },
        isCurrent: isCurrent,
      );
    } finally {
      password.fillRange(0, password.length, 0);
      gatewayPassword.wipe();
    }
  }

  Future<RdpGatewayCertificateObservation> _inspect({
    required String method,
    required RdpGatewayCertificateKind kind,
    required Map<String, Object> arguments,
    required bool Function() isCurrent,
  }) async {
    if (_closed || !isCurrent()) throw const RdpFailure('retired');
    if (_activeRequestId != null) throw const RdpFailure('busy');
    final requestId = _schema6Uuid(_random);
    _activeRequestId = requestId;
    try {
      final raw = await _methods
          .invokeMethod<Object?>(method, {
            'schemaVersion': 6,
            'requestId': requestId,
            ...arguments,
          })
          .timeout(deadline);
      if (_closed || !isCurrent() || _activeRequestId != requestId) {
        throw const RdpFailure('retired');
      }
      return RdpGatewayCertificateObservation.fromWire(
        raw,
        requestId: requestId,
        kind: kind,
      );
    } on TimeoutException {
      await _cancel();
      throw const RdpFailure('timed_out');
    } on PlatformException catch (error) {
      throw RdpFailure(_gatewayFailure(error.code));
    } finally {
      if (_activeRequestId == requestId) _activeRequestId = null;
    }
  }

  Future<void> _cancel() async {
    try {
      final result = await _methods
          .invokeMethod<Object?>('cancel')
          .timeout(const Duration(seconds: 1));
      if (result != null) throw const RdpFailure('invalid_response');
    } catch (_) {
      // Cancellation is best effort. Native owns the exact request identity.
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final requestId = _activeRequestId;
    _activeRequestId = null;
    if (requestId != null) unawaited(_cancel());
  }
}

String _schema6Uuid(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final encoded = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${encoded.substring(0, 8)}-${encoded.substring(8, 12)}-'
      '${encoded.substring(12, 16)}-${encoded.substring(16, 20)}-'
      '${encoded.substring(20)}';
}

String _transferFailure(String code) => switch (code) {
  'invalidRequest' => 'invalid_response',
  'staleSession' => 'retired',
  'foregroundRequired' => 'foreground_required',
  'busy' => 'busy',
  'engineUnavailable' => 'engine_unavailable',
  'unavailable' => 'file_transfer_unavailable',
  'authorityChanged' => 'authority_changed',
  _ => 'file_transfer_failed',
};

String _gatewayFailure(String code) => switch (code) {
  'invalidRequest' => 'invalid_response',
  'staleSession' => 'retired',
  'foregroundRequired' => 'foreground_required',
  'busy' => 'busy',
  'engineUnavailable' => 'engine_unavailable',
  'connectionFailed' => 'connection_failed',
  _ => 'connection_failed',
};
