import 'dart:async';

import 'rdp_engine.dart';
import 'rdp_models.dart';
import 'rdp_schema6_controller.dart';
import 'rdp_schema6_models.dart';

/// Binds one planned public session owner to one private mirror transfer. The
/// native process-owner token remains private and is never represented here.
final class RdpSchema6SessionAuthority {
  RdpSchema6SessionAuthority({
    required RdpSchema6TransferCoordinator transfer,
    required bool Function() isCurrent,
  }) : this._(transfer, isCurrent);

  RdpSchema6SessionAuthority.gatewayOnly({required bool Function() isCurrent})
    : this._(null, isCurrent);

  RdpSchema6SessionAuthority._(this._transfer, this._isCurrent);

  final RdpSchema6TransferCoordinator? _transfer;
  final bool Function() _isCurrent;
  RdpSchema6SessionBinding? _binding;
  RdpChannel? _channel;
  Future<RdpTransferReceipt>? _draining;
  bool _closed = false;

  RdpSchema6SessionBinding? get binding => _binding;
  RdpTransferReceipt? get receipt => _transfer?.receipt;
  bool get successorBlocked => _transfer?.successorBlocked ?? false;
  bool get hasFileTransfer => _transfer != null;

  Future<RdpChannel> open({
    required RdpSchema6NativeSessionGateway gateway,
    required RdpSessionRequest request,
    required RdpCredential credential,
    required RdpSchema6SessionOwner owner,
  }) async {
    _check();
    if (_binding != null || _channel != null || _draining != null) {
      throw const RdpFailure('busy');
    }
    final transfer = _transfer;
    final RdpSchema6SessionBinding binding;
    if (transfer == null) {
      binding = RdpSchema6SessionBinding(owner: owner);
    } else {
      final prepared = await transfer.prepare(owner);
      _check();
      if (prepared.state != RdpTransferState.prepared) {
        throw const RdpFailure('invalid_response');
      }
      binding = transfer.consumeSessionBinding();
    }
    _binding = binding;
    try {
      final channel = await gateway.openOwned(
        request,
        credential: credential,
        binding: binding,
        isCurrent: _current,
      );
      _check();
      _channel = channel;
      unawaited(
        channel.done.then<void>(
          (_) async {
            if (_transfer != null) {
              try {
                await closeAndDrain();
              } catch (_) {}
            } else if (identical(_channel, channel)) {
              _channel = null;
              _binding = null;
            }
          },
          onError: (_) async {
            if (_transfer != null) {
              try {
                await closeAndDrain();
              } catch (_) {}
            } else if (identical(_channel, channel)) {
              _channel = null;
              _binding = null;
            }
          },
        ),
      );
      return channel;
    } catch (error, stack) {
      if (_transfer != null) {
        try {
          await _drainExact();
        } catch (_) {}
      } else {
        _channel = null;
        _binding = null;
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Closing the transport only seals the private mirror. It never writes SAF.
  Future<RdpTransferReceipt> closeAndDrain() async {
    _channel?.close();
    _channel = null;
    return _drainExact();
  }

  Future<RdpTransferReceipt> _drainExact() {
    final transfer = _transfer;
    if (transfer == null) {
      return Future.error(const RdpFailure('invalid_request'));
    }
    final pending = _draining;
    if (pending != null) return pending;
    final binding = _binding;
    if (binding == null) {
      return Future.error(const RdpFailure('invalid_request'));
    }
    final future = transfer.drain().then(
      (result) {
        if (result.transferId != binding.transfer!.transferId ||
            result.state != RdpTransferState.sealed &&
                result.state != RdpTransferState.unknown) {
          throw const RdpFailure('invalid_response');
        }
        return result;
      },
      onError: (Object error, StackTrace stack) {
        Error.throwWithStackTrace(error, stack);
      },
    );
    _draining = future;
    return future;
  }

  /// Explicit user action is the sole path that may publish received files.
  Future<RdpTransferReceipt> saveReceived() async {
    final transfer = _transfer;
    if (transfer == null) throw const RdpFailure('invalid_request');
    final drained = _draining;
    if (drained != null) await drained;
    _check();
    return transfer.saveReceived();
  }

  Future<RdpTransferReceipt> observe() => _transfer == null
      ? Future.error(const RdpFailure('invalid_request'))
      : _transfer.observe();

  bool _current() {
    if (_closed) return false;
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }

  void _check() {
    if (!_current()) throw const RdpFailure('retired');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _channel?.close();
    _channel = null;
    if (_binding == null) {
      // A pending prepare may still return. Closing its coordinator prevents
      // that exact late receipt from becoming a successor's session binding.
      _transfer?.close();
      return;
    }
    if (_transfer != null && _binding != null && _draining == null) {
      // Keep the exact pair and mirror fenced. Native drain is asynchronous;
      // disposal cannot turn an unobserved close into a successful seal.
      unawaited(_drainExact().then<void>((_) {}, onError: (_, _) {}));
    }
  }
}
