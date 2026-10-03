import 'dart:async';

import 'rdp_models.dart';
import 'rdp_schema6_engine.dart';
import 'rdp_schema6_models.dart';
import 'rdp_schema6_security_store.dart';
import 'rdp_security_store.dart';

/// Two-stage, non-replayable Gateway enrollment. Certificate observations are
/// never persisted here; the caller explicitly accepts public pins.
final class RdpGatewayEnrollmentCoordinator {
  factory RdpGatewayEnrollmentCoordinator({
    required RdpGatewayEnrollmentEngine engine,
    required RdpSchema6SecretVault secrets,
    required RdpSchema6SecretScope scope,
    required bool Function() isCurrent,
  }) => RdpGatewayEnrollmentCoordinator._(engine, secrets, scope, isCurrent);

  RdpGatewayEnrollmentCoordinator._(
    this._engine,
    this._secrets,
    this._scope,
    this._isCurrent,
  );

  final RdpGatewayEnrollmentEngine _engine;
  final RdpSchema6SecretVault _secrets;
  final RdpSchema6SecretScope _scope;
  final bool Function() _isCurrent;
  int _generation = 0;
  bool _closed = false;

  Future<RdpGatewayCertificateObservation> inspectGateway({
    required RdpGatewayEndpoint target,
    required RdpGatewayEndpoint gateway,
  }) async {
    final generation = _capture();
    final result = await _engine.inspectGateway(
      target: target,
      gateway: gateway,
      isCurrent: () => _current(generation),
    );
    _requireCurrent(generation);
    return result;
  }

  Future<RdpGatewayCertificateObservation> inspectTarget({
    required RdpGatewayEndpoint target,
    required RdpPinnedGatewayEndpoint gateway,
    required RdpDeviceSecretReference gatewaySecret,
  }) async {
    final generation = _capture();
    final secret = await _secrets.resolve(
      scope: _scope,
      kind: RdpSchema6SecretKind.gatewayPassword,
      reference: gatewaySecret,
      isCurrent: () => _current(generation),
    );
    try {
      _requireCurrent(generation);
      final result = await _engine.inspectTargetThroughGateway(
        target: target,
        gateway: gateway,
        gatewayPassword: secret,
        isCurrent: () => _current(generation),
      );
      _requireCurrent(generation);
      return result;
    } finally {
      secret.wipe();
    }
  }

  int _capture() {
    final generation = _generation;
    _requireCurrent(generation);
    return generation;
  }

  bool _current(int generation) {
    if (_closed || generation != _generation) return false;
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _requireCurrent(int generation) {
    if (!_current(generation)) throw const RdpFailure('retired');
  }

  void retire() {
    if (_closed) return;
    _generation += 1;
    _engine.close();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _generation += 1;
    _engine.close();
  }
}

/// Owns one transfer journal at a time. It cannot turn a native close failure
/// into success and cannot publish SAF documents without an explicit save.
final class RdpSchema6TransferCoordinator {
  factory RdpSchema6TransferCoordinator({
    required RdpSchema6TransferPort port,
    required RdpFileTransferAuthority authority,
    required RdpFileTransferGrant grant,
    required bool Function() isCurrent,
  }) {
    grant.validate();
    return RdpSchema6TransferCoordinator._(port, authority, grant, isCurrent);
  }

  RdpSchema6TransferCoordinator._(
    this._port,
    this._authority,
    this._grant,
    this._isCurrent,
  );

  final RdpSchema6TransferPort _port;
  final RdpFileTransferAuthority _authority;
  final RdpFileTransferGrant _grant;
  final bool Function() _isCurrent;
  RdpTransferReceipt? _receipt;
  RdpSchema6SessionOwner? _owner;
  bool _bound = false;
  bool _busy = false;
  bool _closed = false;
  int _generation = 0;

  RdpTransferReceipt? get receipt => _receipt;
  bool get successorBlocked => switch (_receipt?.state) {
    null || RdpTransferState.saved => false,
    _ => true,
  };

  Future<RdpTransferReceipt> prepare(RdpSchema6SessionOwner owner) =>
      _serial(() async {
        if (successorBlocked) throw const RdpFailure('busy');
        final generation = _generation;
        final result = await _port.prepare(
          authority: _authority,
          grant: _grant,
          sessionOwner: owner,
          isCurrent: () => _current(generation),
        );
        if (result.state != RdpTransferState.prepared) _invalidResponse();
        if (!_current(generation)) {
          // The prepare receipt belongs to this exact owner, but the UI scope
          // retired before it could be consumed. Preserve a fenced unknown
          // record locally; never let a successor adopt the late receipt.
          _receipt = _localState(result, RdpTransferState.unknown);
          _owner = owner;
          _bound = false;
          throw const RdpFailure('retired');
        }
        _receipt = result;
        _owner = owner;
        _bound = false;
        return result;
      });

  RdpSchema6SessionBinding consumeSessionBinding() {
    _requireCurrent(_generation);
    final receipt = _receipt;
    if (receipt == null ||
        receipt.state != RdpTransferState.prepared ||
        _bound) {
      throw const RdpFailure('busy');
    }
    _bound = true;
    final owner = _owner;
    if (owner == null) throw const RdpFailure('invalid_request');
    return RdpSchema6SessionBinding(owner: owner, transfer: receipt);
  }

  Future<RdpTransferReceipt> observe() => _serial(() async {
    final receipt = _requireReceipt();
    final owner = _requireOwner();
    final generation = _generation;
    final result = await _port.observe(
      authority: _authority,
      grant: _grant,
      transferId: receipt.transferId,
      sessionOwner: owner,
      isCurrent: () => _current(generation),
    );
    _requireCurrent(generation);
    if (result.transferId != receipt.transferId) _invalidResponse();
    _receipt = result;
    return result;
  });

  Future<RdpTransferReceipt> drain() => _serial(() async {
    final receipt = _requireReceipt();
    final owner = _requireOwner();
    if (!_bound ||
        receipt.state == RdpTransferState.saved ||
        receipt.state == RdpTransferState.unknown) {
      throw const RdpFailure('invalid_request');
    }
    final generation = _generation;
    try {
      final result = await _port.drain(
        authority: _authority,
        grant: _grant,
        transferId: receipt.transferId,
        sessionOwner: owner,
        isCurrent: () => _cleanupCurrent(generation, receipt, owner),
      );
      _requireCleanupCurrent(generation, receipt, owner);
      if (result.transferId != receipt.transferId ||
          result.state != RdpTransferState.sealed &&
              result.state != RdpTransferState.unknown) {
        _invalidResponse();
      }
      _receipt = result;
      return result;
    } catch (_) {
      _receipt = _localState(receipt, RdpTransferState.unknown);
      rethrow;
    }
  }, cleanup: true);

  Future<RdpTransferReceipt> saveReceived() => _serial(() async {
    final receipt = _requireReceipt();
    final owner = _requireOwner();
    if (receipt.state != RdpTransferState.sealed) {
      throw const RdpFailure('invalid_request');
    }
    final generation = _generation;
    try {
      final result = await _port.saveReceived(
        authority: _authority,
        grant: _grant,
        transferId: receipt.transferId,
        sessionOwner: owner,
        isCurrent: () => _current(generation),
      );
      _requireCurrent(generation);
      if (result.transferId != receipt.transferId ||
          result.state != RdpTransferState.saved &&
              result.state != RdpTransferState.unknown) {
        _invalidResponse();
      }
      _receipt = result;
      return result;
    } catch (_) {
      _receipt = _localState(receipt, RdpTransferState.unknown);
      rethrow;
    }
  });

  RdpTransferReceipt _requireReceipt() {
    _requireCurrent(_generation);
    final receipt = _receipt;
    if (receipt == null) throw const RdpFailure('invalid_request');
    return receipt;
  }

  RdpSchema6SessionOwner _requireOwner() {
    final owner = _owner;
    if (owner == null) throw const RdpFailure('invalid_request');
    return owner;
  }

  Future<RdpTransferReceipt> _serial(
    Future<RdpTransferReceipt> Function() action, {
    bool cleanup = false,
  }) async {
    if (_busy) throw const RdpFailure('busy');
    if (cleanup) {
      final receipt = _requireReceiptForCleanup();
      _requireCleanupCurrent(_generation, receipt, _requireOwner());
    } else {
      _requireCurrent(_generation);
    }
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  RdpTransferReceipt _requireReceiptForCleanup() {
    final receipt = _receipt;
    if (receipt == null) throw const RdpFailure('invalid_request');
    return receipt;
  }

  bool _cleanupCurrent(
    int generation,
    RdpTransferReceipt receipt,
    RdpSchema6SessionOwner owner,
  ) =>
      !_closed &&
      generation == _generation &&
      identical(receipt, _receipt) &&
      identical(owner, _owner) &&
      _bound;

  void _requireCleanupCurrent(
    int generation,
    RdpTransferReceipt receipt,
    RdpSchema6SessionOwner owner,
  ) {
    if (!_cleanupCurrent(generation, receipt, owner)) {
      throw const RdpFailure('retired');
    }
  }

  bool _current(int generation) {
    if (_closed || generation != _generation) return false;
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _requireCurrent(int generation) {
    if (!_current(generation)) throw const RdpFailure('retired');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _generation += 1;
    if (_receipt case final receipt?
        when receipt.state != RdpTransferState.saved) {
      _receipt = _localState(receipt, RdpTransferState.unknown);
    }
  }
}

RdpTransferReceipt _localState(
  RdpTransferReceipt receipt,
  RdpTransferState state,
) => RdpTransferReceipt(
  requestId: receipt.requestId,
  authorityId: receipt.authorityId,
  grant: receipt.grant,
  transferId: receipt.transferId,
  state: state,
);

Never _invalidResponse() => throw const RdpFailure('invalid_response');
