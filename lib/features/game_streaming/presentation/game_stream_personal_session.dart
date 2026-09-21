// ignore_for_file: prefer_initializing_formals

import '../data/android_game_stream_port.dart';
import '../domain/game_stream_session.dart';

/// Joins a device-personal account/route lease to the native Android binding.
/// It carries no host address, PIN, token, pairing key, or input data.
final class GameStreamPersonalSessionBinder {
  GameStreamPersonalSessionBinder({
    required GameStreamNativeBindingPort port,
    required Object Function() accountOwnerResolver,
    required Object Function() routeOwnerResolver,
    required GameStreamAuthority Function() authorityResolver,
    required GameStreamSessionState Function() sessionResolver,
    required bool Function() gateCurrent,
    required bool Function() routeCurrent,
  }) : _port = port,
       _accountOwnerResolver = accountOwnerResolver,
       _routeOwnerResolver = routeOwnerResolver,
       _authorityResolver = authorityResolver,
       _sessionResolver = sessionResolver,
       _gateCurrent = gateCurrent,
       _routeCurrent = routeCurrent;

  final GameStreamNativeBindingPort _port;
  final Object Function() _accountOwnerResolver;
  final Object Function() _routeOwnerResolver;
  final GameStreamAuthority Function() _authorityResolver;
  final GameStreamSessionState Function() _sessionResolver;
  final bool Function() _gateCurrent;
  final bool Function() _routeCurrent;

  int _epoch = 0;
  AndroidGameStreamBinding? _binding;

  Future<int> bind({
    required Object accountOwner,
    required Object routeOwner,
    required GameStreamAuthority authority,
    required GameStreamSessionState session,
    required AndroidGameStreamCredentialHandle credentialHandle,
  }) async {
    final epoch = ++_epoch;
    final previous = _binding;
    _binding = null;
    if (previous != null) {
      await _retireExact(previous);
      if (epoch != _epoch) {
        throw const GameStreamException('stale_personal_session');
      }
    }
    if (!_current(accountOwner, routeOwner, authority, session)) {
      throw const GameStreamException('stale_personal_session');
    }
    final binding = AndroidGameStreamBinding(
      sessionId: session.sessionId,
      epoch: epoch,
      accountRevision: authority.accountRevision,
      routeRevision: authority.routeRevision,
      lifecycleRevision: authority.lifecycleRevision,
      idleRevision: authority.idleRevision,
      interactionRevision: authority.interactionRevision,
      credentialHandle: credentialHandle,
    );
    await _port.bind(binding);
    if (epoch != _epoch ||
        !_current(accountOwner, routeOwner, authority, session)) {
      await _retireExact(binding);
      throw const GameStreamException('stale_personal_session');
    }
    _binding = binding;
    return epoch;
  }

  Future<void> retire() async {
    _epoch += 1;
    final binding = _binding;
    _binding = null;
    if (binding != null) await _retireExact(binding);
  }

  bool _current(
    Object accountOwner,
    Object routeOwner,
    GameStreamAuthority authority,
    GameStreamSessionState session,
  ) {
    try {
      final current = _sessionResolver();
      return identical(_accountOwnerResolver(), accountOwner) &&
          identical(_routeOwnerResolver(), routeOwner) &&
          _authorityResolver() == authority &&
          current.sessionId == session.sessionId &&
          current.revisions == session.revisions &&
          !current.outcomeUnknown &&
          current.phase != GameStreamPhase.retired &&
          current.phase != GameStreamPhase.rejected &&
          current.phase != GameStreamPhase.outcomeUnknown &&
          current.phase != GameStreamPhase.stopped &&
          authority.pinUnlocked &&
          authority.foreground &&
          authority.routeVisible &&
          authority.interactionActive &&
          !authority.idle &&
          _gateCurrent() &&
          _routeCurrent();
    } catch (_) {
      return false;
    }
  }

  Future<void> _retireExact(AndroidGameStreamBinding binding) async {
    try {
      await _port.retireBinding(binding);
    } catch (_) {
      // Local ownership has already been revoked. A stale native binding can
      // only fail closed; it is never reused or treated as retired evidence.
    }
  }
}
