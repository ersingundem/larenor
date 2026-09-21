import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/multi_display/domain/dual_display_session.dart';

const account = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const session = '33333333333333333333333333333333';

DisplayRouteAuthority authority({
  int accountRevision = 3,
  int routeRevision = 8,
}) {
  return DisplayRouteAuthority(
    accountId: account,
    accountRevision: accountRevision,
    homeId: home,
    homeRevision: 5,
    sessionFamilyId: session,
    routeRevision: routeRevision,
    lifecycleEpoch: 11,
    interactionEpoch: 13,
    allowedSecondaryRoutes: const {'dashboard.overview', 'media.now-playing'},
  );
}

DisplaySurface primary({int generation = 2}) => DisplaySurface(
  displayId: 0,
  generation: generation,
  kind: DisplayKind.primary,
  widthPixels: 1600,
  heightPixels: 2560,
  densityDpi: 320,
  securePresentation: true,
);

DisplaySurface external({int displayId = 7, int generation = 4}) =>
    DisplaySurface(
      displayId: displayId,
      generation: generation,
      kind: DisplayKind.external,
      widthPixels: 1920,
      heightPixels: 1080,
      densityDpi: 160,
      securePresentation: true,
    );

DisplayTopology topology({bool withExternal = true, int revision = 9}) {
  return DisplayTopology(
    revision: revision,
    surfaces: [primary(), if (withExternal) external()],
  );
}

DisplayRouteSelection selection({
  RouteSensitivity sensitivity = RouteSensitivity.public,
  DisplayOwner playerOwner = DisplayOwner.secondary,
}) {
  return DisplayRouteSelection(
    primaryRouteId: 'dashboard.home',
    secondaryRouteId: 'media.now-playing',
    secondarySensitivity: sensitivity,
    focusOwner: DisplayOwner.primary,
    playerOwner: playerOwner,
  );
}

final class FakeDisplayPort implements SecondaryDisplayPort {
  final requests = <SecondaryPresentationRequest>[];
  final dismissals = <SecondaryDismissal>[];
  Completer<SecondaryPresentationReceipt>? pending;
  bool succeed = true;

  @override
  Future<SecondaryPresentationReceipt> present(
    SecondaryPresentationRequest request,
  ) async {
    requests.add(request);
    final completer = pending;
    if (completer != null) return completer.future;
    return SecondaryPresentationReceipt(
      sessionId: request.sessionId,
      displayId: request.display.displayId,
      displayGeneration: request.display.generation,
      topologyRevision: request.topologyRevision,
      routeId: request.routeId,
      attached: succeed,
    );
  }

  @override
  Future<void> dismiss(SecondaryDismissal dismissal) async {
    dismissals.add(dismissal);
  }
}

void main() {
  test(
    'exact route authority activates isolated public secondary role',
    () async {
      var liveAuthority = authority();
      var liveTopology = topology();
      final port = FakeDisplayPort();
      final coordinator = DualDisplayCoordinator(
        authorityResolver: () => liveAuthority,
        topologyResolver: () => liveTopology,
        port: port,
      );

      final state = await coordinator.activate(
        authority: liveAuthority,
        topology: liveTopology,
        secondaryDisplayId: 7,
        selection: selection(),
      );
      expect(state.status, DualDisplayStatus.active);
      expect(state.primaryRouteId, 'dashboard.home');
      expect(state.secondaryRouteId, 'media.now-playing');
      expect(state.focusOwner, DisplayOwner.primary);
      expect(state.playerOwner, DisplayOwner.secondary);
      expect(port.requests, hasLength(1));
      expect(port.requests.single.routeId, 'media.now-playing');

      final diagnostics = state.toDiagnostics().toString();
      expect(diagnostics, isNot(contains(account)));
      expect(diagnostics, isNot(contains(session)));
      expect(diagnostics, isNot(contains('token')));
      expect(diagnostics, isNot(contains('http')));

      liveAuthority = authority(accountRevision: 4);
      await expectLater(
        coordinator.activate(
          authority: authority(),
          topology: liveTopology,
          secondaryDisplayId: 7,
          selection: selection(),
        ),
        throwsA(
          isA<DualDisplayException>().having(
            (e) => e.code,
            'code',
            'stale_authority',
          ),
        ),
      );
      expect(port.requests, hasLength(1));
    },
  );

  test(
    'missing or detached external display retires without route migration',
    () async {
      var liveTopology = topology(withExternal: false);
      final port = FakeDisplayPort();
      final coordinator = DualDisplayCoordinator(
        authorityResolver: authority,
        topologyResolver: () => liveTopology,
        port: port,
      );
      final missing = await coordinator.activate(
        authority: authority(),
        topology: liveTopology,
        secondaryDisplayId: 7,
        selection: selection(),
      );
      expect(missing.status, DualDisplayStatus.primaryOnly);
      expect(missing.reason, DualDisplayReason.secondaryUnavailable);
      expect(missing.secondaryRouteId, isNull);
      expect(missing.playerOwner, DisplayOwner.none);
      expect(port.requests, isEmpty);

      liveTopology = topology();
      final active = await coordinator.activate(
        authority: authority(),
        topology: liveTopology,
        secondaryDisplayId: 7,
        selection: selection(),
      );
      expect(active.status, DualDisplayStatus.active);
      liveTopology = topology(withExternal: false, revision: 10);
      final detached = await coordinator.updateTopology(liveTopology);
      expect(detached.status, DualDisplayStatus.retired);
      expect(detached.reason, DualDisplayReason.secondaryDetached);
      expect(detached.secondaryRouteId, isNull);
      expect(detached.playerOwner, DisplayOwner.none);
      expect(detached.primaryRouteId, 'dashboard.home');
      expect(port.dismissals, hasLength(1));
    },
  );

  test(
    'detach and lifecycle retirement reject late presentation callbacks',
    () async {
      var liveTopology = topology();
      final port = FakeDisplayPort()..pending = Completer();
      final coordinator = DualDisplayCoordinator(
        authorityResolver: authority,
        topologyResolver: () => liveTopology,
        port: port,
      );
      final activation = coordinator.activate(
        authority: authority(),
        topology: liveTopology,
        secondaryDisplayId: 7,
        selection: selection(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.state.status, DualDisplayStatus.presenting);

      liveTopology = topology(withExternal: false, revision: 10);
      await coordinator.updateTopology(liveTopology);
      final request = port.requests.single;
      port.pending!.complete(
        SecondaryPresentationReceipt(
          sessionId: request.sessionId,
          displayId: request.display.displayId,
          displayGeneration: request.display.generation,
          topologyRevision: request.topologyRevision,
          routeId: request.routeId,
          attached: true,
        ),
      );
      final late = await activation;
      expect(late.status, DualDisplayStatus.retired);
      expect(coordinator.state.status, DualDisplayStatus.retired);
      expect(coordinator.state.secondaryRouteId, isNull);

      liveTopology = topology(revision: 11);
      port.pending = null;
      await coordinator.activate(
        authority: authority(),
        topology: liveTopology,
        secondaryDisplayId: 7,
        selection: selection(),
      );
      final paused = await coordinator.updateLifecycle(DisplayLifecycle.paused);
      expect(paused.reason, DualDisplayReason.lifecycleRetired);
      expect(paused.secondaryRouteId, isNull);
      await coordinator.updateLifecycle(DisplayLifecycle.resumed);
      expect(coordinator.state.status, DualDisplayStatus.retired);
      expect(port.requests, hasLength(2));
    },
  );

  test('private, unknown and malformed secondary routes fail closed', () async {
    final port = FakeDisplayPort();
    final coordinator = DualDisplayCoordinator(
      authorityResolver: authority,
      topologyResolver: topology,
      port: port,
    );
    for (final value in [
      selection(sensitivity: RouteSensitivity.private),
      DisplayRouteSelection(
        primaryRouteId: 'dashboard.home',
        secondaryRouteId: 'admin.secrets',
        secondarySensitivity: RouteSensitivity.public,
        focusOwner: DisplayOwner.primary,
        playerOwner: DisplayOwner.none,
      ),
    ]) {
      await expectLater(
        coordinator.activate(
          authority: authority(),
          topology: topology(),
          secondaryDisplayId: 7,
          selection: value,
        ),
        throwsA(isA<DualDisplayException>()),
      );
    }
    expect(port.requests, isEmpty);
    expect(
      () => DisplayRouteSelection(
        primaryRouteId: 'https://secret.invalid',
        secondaryRouteId: 'media.now-playing',
        secondarySensitivity: RouteSensitivity.public,
        focusOwner: DisplayOwner.primary,
        playerOwner: DisplayOwner.none,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('invalid presentation receipt is dismissed exactly once', () async {
    final port = FakeDisplayPort();
    final coordinator = DualDisplayCoordinator(
      authorityResolver: authority,
      topologyResolver: topology,
      port: port,
    );
    port.pending = Completer();

    final activation = coordinator.activate(
      authority: authority(),
      topology: topology(),
      secondaryDisplayId: 7,
      selection: selection(),
    );
    await Future<void>.delayed(Duration.zero);
    final request = port.requests.single;
    port.pending!.complete(
      SecondaryPresentationReceipt(
        sessionId: request.sessionId,
        displayId: request.display.displayId,
        displayGeneration: request.display.generation + 1,
        topologyRevision: request.topologyRevision,
        routeId: request.routeId,
        attached: true,
      ),
    );

    final state = await activation;
    expect(state.status, DualDisplayStatus.retired);
    expect(state.reason, DualDisplayReason.presentationFailed);
    expect(port.dismissals, hasLength(1));
  });

  test(
    'replacement, missing display and authority rotation retire old lease',
    () async {
      var liveAuthority = authority();
      var liveTopology = DisplayTopology(
        revision: 9,
        surfaces: [primary(), external(), external(displayId: 8)],
      );
      final port = FakeDisplayPort();
      final coordinator = DualDisplayCoordinator(
        authorityResolver: () => liveAuthority,
        topologyResolver: () => liveTopology,
        port: port,
      );

      await coordinator.activate(
        authority: liveAuthority,
        topology: liveTopology,
        secondaryDisplayId: 7,
        selection: selection(),
      );
      await coordinator.activate(
        authority: liveAuthority,
        topology: liveTopology,
        secondaryDisplayId: 8,
        selection: selection(),
      );
      expect(port.dismissals.map((value) => value.displayId), [7]);
      expect(coordinator.state.secondaryDisplayId, 8);

      liveTopology = topology(withExternal: false, revision: 10);
      final missing = await coordinator.activate(
        authority: liveAuthority,
        topology: liveTopology,
        secondaryDisplayId: 8,
        selection: selection(),
      );
      expect(missing.status, DualDisplayStatus.primaryOnly);
      expect(missing.secondaryDisplayId, isNull);
      expect(port.dismissals.map((value) => value.displayId), [7, 8]);

      liveTopology = topology(revision: 11);
      await coordinator.activate(
        authority: liveAuthority,
        topology: liveTopology,
        secondaryDisplayId: 7,
        selection: selection(),
      );
      liveAuthority = authority(accountRevision: 4);
      final retired = await coordinator.updateAuthority(liveAuthority);
      expect(retired.status, DualDisplayStatus.retired);
      expect(retired.reason, DualDisplayReason.staleAuthority);
      expect(retired.secondaryDisplayId, isNull);
      expect(port.dismissals.map((value) => value.displayId), [7, 8, 7]);
    },
  );

  test('topology and public state stay bounded and secret-free', () {
    expect(
      () => DisplayTopology(
        revision: 1,
        surfaces: [
          primary(),
          for (var i = 1; i <= 5; i++) external().copyWith(displayId: i),
        ],
      ),
      throwsA(isA<ArgumentError>()),
    );
    final state = DualDisplayState.primaryOnly(
      topology: topology(withExternal: false),
      primaryRouteId: 'dashboard.home',
      reason: DualDisplayReason.secondaryUnavailable,
    );
    expect(state.toString(), 'DualDisplayState(primaryOnly)');
    expect(state.toDiagnostics().keys.toSet(), {
      'status',
      'reason',
      'topologyRevision',
      'primaryKind',
      'secondaryAttached',
      'focusOwner',
      'playerOwner',
    });
  });
}
