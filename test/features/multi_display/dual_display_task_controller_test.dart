import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/multi_display/data/dual_display_platform_port.dart';
import 'package:larenor/features/multi_display/data/dual_display_task_controller.dart';
import 'package:larenor/features/multi_display/domain/dual_display_session.dart';

const id1 = '11111111111111111111111111111111';
const id2 = '22222222222222222222222222222222';
const id3 = '33333333333333333333333333333333';

DisplayRouteAuthority exactAuthority() => DisplayRouteAuthority(
  accountId: id1,
  accountRevision: 3,
  homeId: id2,
  homeRevision: 5,
  sessionFamilyId: id3,
  routeRevision: 7,
  lifecycleEpoch: 11,
  interactionEpoch: 13,
  allowedSecondaryRoutes: const {'dashboard.overview', 'media.now-playing'},
);

DisplaySurface tablet() => DisplaySurface(
  displayId: 0,
  generation: 2,
  kind: DisplayKind.primary,
  widthPixels: 1600,
  heightPixels: 2560,
  densityDpi: 320,
  securePresentation: true,
);

DisplaySurface monitor(int generation) => DisplaySurface(
  displayId: 4,
  generation: generation,
  kind: DisplayKind.external,
  widthPixels: 1920,
  heightPixels: 1080,
  densityDpi: 160,
  securePresentation: true,
);

DisplayTopology screens(int revision, {int? externalGeneration = 5}) =>
    DisplayTopology(
      revision: revision,
      surfaces: [
        tablet(),
        if (externalGeneration != null) monitor(externalGeneration),
      ],
    );

final class Platform implements DualDisplayPlatformPort {
  Platform(this.snapshotValue);
  DisplayTopology snapshotValue;
  final presented = <SecondaryPresentationRequest>[];
  final dismissed = <SecondaryDismissal>[];
  Completer<SecondaryPresentationReceipt>? pending;

  @override
  Future<DisplayTopology> snapshot() async => snapshotValue;

  @override
  Future<SecondaryPresentationReceipt> present(
    SecondaryPresentationRequest request,
  ) async {
    presented.add(request);
    final waiting = pending;
    if (waiting != null) return waiting.future;
    return SecondaryPresentationReceipt(
      sessionId: request.sessionId,
      displayId: request.display.displayId,
      displayGeneration: request.display.generation,
      topologyRevision: request.topologyRevision,
      routeId: request.routeId,
      attached: true,
    );
  }

  @override
  Future<void> dismiss(SecondaryDismissal dismissal) async {
    dismissed.add(dismissal);
  }
}

void main() {
  test(
    'disconnect and reconnect reject stale display and use new generation',
    () async {
      var current = true;
      final platform = Platform(screens(7));
      final controller = DualDisplayTaskController(
        platform,
        exactAuthority,
        () => current,
      );
      addTearDown(() {
        current = false;
        controller.dispose();
      });

      await controller.refresh();
      final first = controller.topology!.externalById(4)!;
      await controller.activate(first, 'media.now-playing');
      expect(controller.state?.status, DualDisplayStatus.active);

      platform.snapshotValue = screens(8, externalGeneration: null);
      await controller.refresh();
      expect(controller.state?.reason, DualDisplayReason.secondaryDetached);
      expect(platform.dismissed, hasLength(1));

      platform.snapshotValue = screens(9, externalGeneration: 6);
      await controller.refresh();
      await controller.activate(first, 'media.now-playing');
      expect(platform.presented, hasLength(1));
      expect(controller.failure, 'stale_display');
      final reconnected = controller.topology!.externalById(4)!;
      await controller.activate(reconnected, 'dashboard.overview');
      expect(platform.presented, hasLength(2));
      expect(platform.presented.last.display.generation, 6);
    },
  );

  test('unknown route and late hidden-route receipt fail closed', () async {
    var current = true;
    final platform = Platform(screens(7));
    final controller = DualDisplayTaskController(
      platform,
      exactAuthority,
      () => current,
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    final display = controller.topology!.externalById(4)!;
    await controller.activate(display, 'admin.secrets');
    expect(platform.presented, isEmpty);
    expect(controller.failure, 'stale_display');

    platform.pending = Completer();
    final pending = controller.activate(display, 'media.now-playing');
    await Future<void>.delayed(Duration.zero);
    current = false;
    final request = platform.presented.single;
    platform.pending!.complete(
      SecondaryPresentationReceipt(
        sessionId: request.sessionId,
        displayId: request.display.displayId,
        displayGeneration: request.display.generation,
        topologyRevision: request.topologyRevision,
        routeId: request.routeId,
        attached: true,
      ),
    );
    await pending;
    expect(platform.dismissed, hasLength(1));
    expect(controller.state?.status, DualDisplayStatus.retired);
  });
}
