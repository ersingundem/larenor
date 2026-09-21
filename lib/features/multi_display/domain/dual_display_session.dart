// ignore_for_file: prefer_initializing_formals

/// Core-independent dual-display authority and lifecycle contract.
///
/// This file intentionally carries route identifiers and public display facts
/// only. It has no URL, token, media payload, credential, or Core transport.
enum DisplayKind { primary, external }

enum DisplayLifecycle { resumed, inactive, paused, detached }

enum DisplayOwner { none, primary, secondary }

enum RouteSensitivity { public, private }

enum DualDisplayStatus { primaryOnly, presenting, active, retired }

enum DualDisplayReason {
  none,
  secondaryUnavailable,
  secondaryDetached,
  lifecycleRetired,
  staleAuthority,
  presentationFailed,
}

final class DualDisplayException implements Exception {
  const DualDisplayException(this.code);

  final String code;

  @override
  String toString() => 'DualDisplayException($code)';
}

final class DisplaySurface {
  DisplaySurface({
    required this.displayId,
    required this.generation,
    required this.kind,
    required this.widthPixels,
    required this.heightPixels,
    required this.densityDpi,
    required this.securePresentation,
  }) {
    if (displayId < 0 ||
        displayId > 63 ||
        generation < 1 ||
        generation > _maxRevision ||
        widthPixels < 320 ||
        widthPixels > 8192 ||
        heightPixels < 320 ||
        heightPixels > 8192 ||
        densityDpi < 72 ||
        densityDpi > 640 ||
        kind == DisplayKind.primary && displayId != 0 ||
        kind == DisplayKind.external && displayId == 0) {
      throw ArgumentError('invalid_display');
    }
  }

  final int displayId;
  final int generation;
  final DisplayKind kind;
  final int widthPixels;
  final int heightPixels;
  final int densityDpi;

  /// Platform capability fact. Private secondary routes remain unsupported by
  /// this foundation even when the platform reports a secure surface.
  final bool securePresentation;

  DisplaySurface copyWith({int? displayId, int? generation}) => DisplaySurface(
    displayId: displayId ?? this.displayId,
    generation: generation ?? this.generation,
    kind: displayId == null
        ? kind
        : displayId == 0
        ? DisplayKind.primary
        : DisplayKind.external,
    widthPixels: widthPixels,
    heightPixels: heightPixels,
    densityDpi: densityDpi,
    securePresentation: securePresentation,
  );

  @override
  bool operator ==(Object other) =>
      other is DisplaySurface &&
      displayId == other.displayId &&
      generation == other.generation &&
      kind == other.kind &&
      widthPixels == other.widthPixels &&
      heightPixels == other.heightPixels &&
      densityDpi == other.densityDpi &&
      securePresentation == other.securePresentation;

  @override
  int get hashCode => Object.hash(
    displayId,
    generation,
    kind,
    widthPixels,
    heightPixels,
    densityDpi,
    securePresentation,
  );
}

final class DisplayTopology {
  DisplayTopology({
    required this.revision,
    required List<DisplaySurface> surfaces,
  }) : surfaces = List.unmodifiable(surfaces) {
    if (revision < 1 ||
        revision > _maxRevision ||
        surfaces.isEmpty ||
        surfaces.length > 5) {
      throw ArgumentError('invalid_topology');
    }
    final ids = surfaces.map((surface) => surface.displayId).toSet();
    if (ids.length != surfaces.length ||
        surfaces
                .where((surface) => surface.kind == DisplayKind.primary)
                .length !=
            1) {
      throw ArgumentError('invalid_topology');
    }
  }

  final int revision;
  final List<DisplaySurface> surfaces;

  DisplaySurface get primary =>
      surfaces.singleWhere((surface) => surface.kind == DisplayKind.primary);

  DisplaySurface? externalById(int id) {
    for (final surface in surfaces) {
      if (surface.kind == DisplayKind.external && surface.displayId == id) {
        return surface;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is DisplayTopology &&
      revision == other.revision &&
      _listEquals(surfaces, other.surfaces);

  @override
  int get hashCode => Object.hash(revision, Object.hashAll(surfaces));
}

final class DisplayRouteAuthority {
  DisplayRouteAuthority({
    required this.accountId,
    required this.accountRevision,
    required this.homeId,
    required this.homeRevision,
    required this.sessionFamilyId,
    required this.routeRevision,
    required this.lifecycleEpoch,
    required this.interactionEpoch,
    required Set<String> allowedSecondaryRoutes,
  }) : allowedSecondaryRoutes = Set.unmodifiable(allowedSecondaryRoutes) {
    if (!_identity.hasMatch(accountId) ||
        !_identity.hasMatch(homeId) ||
        !_identity.hasMatch(sessionFamilyId) ||
        !_revision(accountRevision) ||
        !_revision(homeRevision) ||
        !_revision(routeRevision) ||
        !_revision(lifecycleEpoch) ||
        !_revision(interactionEpoch) ||
        allowedSecondaryRoutes.isEmpty ||
        allowedSecondaryRoutes.length > 16 ||
        allowedSecondaryRoutes.any((route) => !_route.hasMatch(route))) {
      throw ArgumentError('invalid_authority');
    }
  }

  final String accountId;
  final int accountRevision;
  final String homeId;
  final int homeRevision;
  final String sessionFamilyId;
  final int routeRevision;
  final int lifecycleEpoch;
  final int interactionEpoch;
  final Set<String> allowedSecondaryRoutes;

  @override
  bool operator ==(Object other) =>
      other is DisplayRouteAuthority &&
      accountId == other.accountId &&
      accountRevision == other.accountRevision &&
      homeId == other.homeId &&
      homeRevision == other.homeRevision &&
      sessionFamilyId == other.sessionFamilyId &&
      routeRevision == other.routeRevision &&
      lifecycleEpoch == other.lifecycleEpoch &&
      interactionEpoch == other.interactionEpoch &&
      _setEquals(allowedSecondaryRoutes, other.allowedSecondaryRoutes);

  @override
  int get hashCode => Object.hash(
    accountId,
    accountRevision,
    homeId,
    homeRevision,
    sessionFamilyId,
    routeRevision,
    lifecycleEpoch,
    interactionEpoch,
    Object.hashAll(allowedSecondaryRoutes.toList()..sort()),
  );

  @override
  String toString() => 'DisplayRouteAuthority(redacted)';
}

final class DisplayRouteSelection {
  DisplayRouteSelection({
    required this.primaryRouteId,
    required this.secondaryRouteId,
    required this.secondarySensitivity,
    required this.focusOwner,
    required this.playerOwner,
  }) {
    if (!_route.hasMatch(primaryRouteId) ||
        !_route.hasMatch(secondaryRouteId) ||
        focusOwner == DisplayOwner.none ||
        focusOwner == DisplayOwner.secondary &&
            playerOwner == DisplayOwner.primary) {
      throw ArgumentError('invalid_route_selection');
    }
  }

  final String primaryRouteId;
  final String secondaryRouteId;
  final RouteSensitivity secondarySensitivity;
  final DisplayOwner focusOwner;
  final DisplayOwner playerOwner;
}

final class SecondaryPresentationRequest {
  const SecondaryPresentationRequest({
    required this.sessionId,
    required this.topologyRevision,
    required this.display,
    required this.routeId,
  });

  final String sessionId;
  final int topologyRevision;
  final DisplaySurface display;
  final String routeId;

  @override
  String toString() => 'SecondaryPresentationRequest(redacted)';
}

final class SecondaryPresentationReceipt {
  const SecondaryPresentationReceipt({
    required this.sessionId,
    required this.displayId,
    required this.displayGeneration,
    required this.topologyRevision,
    required this.routeId,
    required this.attached,
  });

  final String sessionId;
  final int displayId;
  final int displayGeneration;
  final int topologyRevision;
  final String routeId;
  final bool attached;
}

final class SecondaryDismissal {
  const SecondaryDismissal({required this.sessionId, required this.displayId});
  final String sessionId;
  final int displayId;
}

abstract interface class SecondaryDisplayPort {
  Future<SecondaryPresentationReceipt> present(
    SecondaryPresentationRequest request,
  );
  Future<void> dismiss(SecondaryDismissal dismissal);
}

final class DualDisplayState {
  const DualDisplayState._({
    required this.status,
    required this.reason,
    required this.topologyRevision,
    required this.primaryDisplayId,
    required this.primaryRouteId,
    required this.focusOwner,
    required this.playerOwner,
    this.secondaryDisplayId,
    this.secondaryRouteId,
  });

  factory DualDisplayState.primaryOnly({
    required DisplayTopology topology,
    required String primaryRouteId,
    required DualDisplayReason reason,
    DualDisplayStatus status = DualDisplayStatus.primaryOnly,
  }) => DualDisplayState._(
    status: status,
    reason: reason,
    topologyRevision: topology.revision,
    primaryDisplayId: topology.primary.displayId,
    primaryRouteId: primaryRouteId,
    focusOwner: DisplayOwner.primary,
    playerOwner: DisplayOwner.none,
  );

  factory DualDisplayState.dual({
    required DualDisplayStatus status,
    required DisplayTopology topology,
    required DisplaySurface secondary,
    required DisplayRouteSelection selection,
  }) => DualDisplayState._(
    status: status,
    reason: DualDisplayReason.none,
    topologyRevision: topology.revision,
    primaryDisplayId: topology.primary.displayId,
    secondaryDisplayId: secondary.displayId,
    primaryRouteId: selection.primaryRouteId,
    secondaryRouteId: selection.secondaryRouteId,
    focusOwner: selection.focusOwner,
    playerOwner: selection.playerOwner,
  );

  final DualDisplayStatus status;
  final DualDisplayReason reason;
  final int topologyRevision;
  final int primaryDisplayId;
  final int? secondaryDisplayId;
  final String primaryRouteId;
  final String? secondaryRouteId;
  final DisplayOwner focusOwner;
  final DisplayOwner playerOwner;

  Map<String, Object> toDiagnostics() => {
    'status': status.name,
    'reason': reason.name,
    'topologyRevision': topologyRevision,
    'primaryKind': DisplayKind.primary.name,
    'secondaryAttached': secondaryDisplayId != null,
    'focusOwner': focusOwner.name,
    'playerOwner': playerOwner.name,
  };

  @override
  String toString() => 'DualDisplayState(${status.name})';
}

final class DualDisplayCoordinator {
  DualDisplayCoordinator({
    required DisplayRouteAuthority Function() authorityResolver,
    required DisplayTopology Function() topologyResolver,
    required SecondaryDisplayPort port,
  }) : _authorityResolver = authorityResolver,
       _topologyResolver = topologyResolver,
       _port = port,
       _state = DualDisplayState.primaryOnly(
         topology: topologyResolver(),
         primaryRouteId: 'dashboard.home',
         reason: DualDisplayReason.secondaryUnavailable,
       );

  final DisplayRouteAuthority Function() _authorityResolver;
  final DisplayTopology Function() _topologyResolver;
  final SecondaryDisplayPort _port;
  DisplayLifecycle _lifecycle = DisplayLifecycle.resumed;
  DualDisplayState _state;
  _ActiveDisplay? _active;
  int _epoch = 0;

  DualDisplayState get state => _state;

  Future<DualDisplayState> activate({
    required DisplayRouteAuthority authority,
    required DisplayTopology topology,
    required int secondaryDisplayId,
    required DisplayRouteSelection selection,
  }) async {
    if (_lifecycle != DisplayLifecycle.resumed) {
      throw const DualDisplayException('lifecycle_inactive');
    }
    if (_authorityResolver() != authority) {
      throw const DualDisplayException('stale_authority');
    }
    if (_topologyResolver() != topology) {
      throw const DualDisplayException('stale_topology');
    }
    if (selection.secondarySensitivity != RouteSensitivity.public) {
      throw const DualDisplayException('private_secondary_forbidden');
    }
    if (!authority.allowedSecondaryRoutes.contains(
      selection.secondaryRouteId,
    )) {
      throw const DualDisplayException('route_forbidden');
    }
    final secondary = topology.externalById(secondaryDisplayId);
    if (secondary == null) {
      _epoch++;
      _active = null;
      return _state = DualDisplayState.primaryOnly(
        topology: topology,
        primaryRouteId: selection.primaryRouteId,
        reason: DualDisplayReason.secondaryUnavailable,
      );
    }
    final epoch = ++_epoch;
    final sessionId =
        'display-session-$epoch-${topology.revision}-${secondary.displayId}';
    final active = _ActiveDisplay(
      epoch: epoch,
      sessionId: sessionId,
      authority: authority,
      topology: topology,
      secondary: secondary,
      selection: selection,
    );
    _active = active;
    _state = DualDisplayState.dual(
      status: DualDisplayStatus.presenting,
      topology: topology,
      secondary: secondary,
      selection: selection,
    );
    SecondaryPresentationReceipt receipt;
    try {
      receipt = await _port.present(
        SecondaryPresentationRequest(
          sessionId: sessionId,
          topologyRevision: topology.revision,
          display: secondary,
          routeId: selection.secondaryRouteId,
        ),
      );
    } catch (_) {
      if (_active?.epoch == epoch) {
        await _retire(DualDisplayReason.presentationFailed, topology);
      }
      return _state;
    }
    final exactReceipt =
        receipt.sessionId == sessionId &&
        receipt.displayId == secondary.displayId &&
        receipt.displayGeneration == secondary.generation &&
        receipt.topologyRevision == topology.revision &&
        receipt.routeId == selection.secondaryRouteId &&
        receipt.attached;
    final stillCurrent =
        _active?.epoch == epoch &&
        _lifecycle == DisplayLifecycle.resumed &&
        _authorityResolver() == authority &&
        _topologyResolver() == topology;
    if (!exactReceipt || !stillCurrent) {
      if (_active?.epoch == epoch) {
        await _retire(
          exactReceipt
              ? DualDisplayReason.staleAuthority
              : DualDisplayReason.presentationFailed,
          _topologyResolver(),
        );
      } else {
        // The active lease was already retired while the platform callback was
        // pending. Dismiss the late presentation without mutating newer state.
        await _port.dismiss(
          SecondaryDismissal(
            sessionId: sessionId,
            displayId: secondary.displayId,
          ),
        );
      }
      return _state;
    }
    _state = DualDisplayState.dual(
      status: DualDisplayStatus.active,
      topology: topology,
      secondary: secondary,
      selection: selection,
    );
    return _state;
  }

  Future<DualDisplayState> updateTopology(DisplayTopology topology) async {
    if (_topologyResolver() != topology) {
      throw const DualDisplayException('stale_topology');
    }
    final active = _active;
    if (active == null) return _state;
    if (topology != active.topology) {
      return _retire(DualDisplayReason.secondaryDetached, topology);
    }
    return _state;
  }

  Future<DualDisplayState> updateLifecycle(DisplayLifecycle lifecycle) async {
    _lifecycle = lifecycle;
    if (lifecycle == DisplayLifecycle.resumed || _active == null) return _state;
    return _retire(DualDisplayReason.lifecycleRetired, _topologyResolver());
  }

  Future<DualDisplayState> _retire(
    DualDisplayReason reason,
    DisplayTopology topology,
  ) async {
    final active = _active;
    _epoch++;
    _active = null;
    if (active != null) {
      await _port.dismiss(
        SecondaryDismissal(
          sessionId: active.sessionId,
          displayId: active.secondary.displayId,
        ),
      );
    }
    return _state = DualDisplayState.primaryOnly(
      topology: topology,
      primaryRouteId: active?.selection.primaryRouteId ?? _state.primaryRouteId,
      reason: reason,
      status: DualDisplayStatus.retired,
    );
  }
}

final class _ActiveDisplay {
  const _ActiveDisplay({
    required this.epoch,
    required this.sessionId,
    required this.authority,
    required this.topology,
    required this.secondary,
    required this.selection,
  });
  final int epoch;
  final String sessionId;
  final DisplayRouteAuthority authority;
  final DisplayTopology topology;
  final DisplaySurface secondary;
  final DisplayRouteSelection selection;
}

const _maxRevision = 9223372036854775806;
final _identity = RegExp(r'^[0-9a-f]{32}$');
final _route = RegExp(r'^[a-z][a-z0-9._/-]{0,79}$');
bool _revision(int value) => value >= 1 && value <= _maxRevision;
bool _listEquals<T>(List<T> left, List<T> right) =>
    left.length == right.length &&
    List.generate(
      left.length,
      (index) => left[index] == right[index],
    ).every((value) => value);
bool _setEquals<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);
