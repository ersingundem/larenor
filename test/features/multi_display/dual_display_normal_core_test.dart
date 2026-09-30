import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/multi_display/data/dual_display_authority_api.dart';
import 'package:larenor/features/multi_display/data/dual_display_platform_port.dart';
import 'package:larenor/features/multi_display/data/dual_display_task_controller.dart';
import 'package:larenor/features/multi_display/domain/dual_display_session.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

final class _OwnedDisplay implements DualDisplayPlatformPort {
  _OwnedDisplay(this.phase, this.signalRoot);

  final String phase;
  final Directory signalRoot;
  final presented = <SecondaryPresentationRequest>[];
  final dismissed = <SecondaryDismissal>[];
  final published = <SecondaryPublicSnapshotUpdate>[];

  @override
  Future<DisplayTopology> snapshot() async => DisplayTopology(
    revision: 7,
    surfaces: [
      DisplaySurface(
        displayId: 0,
        generation: 2,
        kind: DisplayKind.primary,
        widthPixels: 1600,
        heightPixels: 2560,
        densityDpi: 320,
        securePresentation: true,
      ),
      DisplaySurface(
        displayId: 4,
        generation: 5,
        kind: DisplayKind.external,
        widthPixels: 1920,
        heightPixels: 1080,
        densityDpi: 160,
        securePresentation: false,
      ),
    ],
  );

  @override
  Future<SecondaryPresentationReceipt> present(
    SecondaryPresentationRequest request,
  ) async {
    presented.add(request);
    expect(request.routeId, 'core.status');
    expect(request.publicSnapshot.dataDiskTotalBytes, greaterThan(0));
    expect(request.toString(), isNot(contains('Bearer')));
    if (phase == 'revoked') {
      File('${signalRoot.path}/presented').writeAsStringSync('1');
      final release = File('${signalRoot.path}/continue');
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!release.existsSync()) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('acceptance_timeout');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
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

  @override
  Future<void> publishPublicSnapshot(
    SecondaryPublicSnapshotUpdate update,
  ) async {
    published.add(update);
  }
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  test(
    'real Client and normal Core gate public presentation authority',
    () async {
      final environment = Platform.environment;
      if (!environment.containsKey('LARENOR_F52_PHASE')) {
        markTestSkipped('requires the F52 normal-Core acceptance runner');
        return;
      }
      final phase = environment['LARENOR_F52_PHASE']!;
      final endpoint = ServerEndpoint(environment['LARENOR_F52_CORE_URL']!);
      final context = ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': environment['LARENOR_F52_CORE_ID'],
        'homeId': environment['LARENOR_F52_HOME_ID'],
      });
      final session = ServerSession(
        endpoint: endpoint,
        accessToken: environment['LARENOR_F52_ACCESS_TOKEN']!,
        refreshToken: 'r' * 64,
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        user: ServerUser(
          id: environment['LARENOR_F52_ACCOUNT_ID']!,
          username: 'admin',
          role: ServerRole.admin,
          mustChangePassword: false,
        ),
        sessionFamilyId: environment['LARENOR_F52_FAMILY_ID'],
        context: context,
      );
      final authority = DualDisplayAuthorityApi(
        LarenorServerApi(endpoint: endpoint),
        session,
      );
      final platform = _OwnedDisplay(
        phase,
        Directory(environment['LARENOR_F52_SIGNAL_ROOT']!),
      );
      var current = true;
      final controller = DualDisplayTaskController.authorized(
        platform,
        (valid) => authority.read(
          lifecycleEpoch: 11,
          interactionEpoch: 13,
          current: valid,
        ),
        () => current,
      );
      addTearDown(() {
        current = false;
        controller.dispose();
        authority.close();
      });

      await controller.refresh();
      await controller.activate(
        controller.topology!.externalById(4)!,
        'core.status',
      );
      expect(platform.presented, hasLength(1));
      if (phase == 'success') {
        expect(controller.state?.status, DualDisplayStatus.active);
        expect(platform.dismissed, isEmpty);
        final initialUpdates = platform.published.length;
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (platform.published.length <= initialUpdates &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(platform.published.length, greaterThan(initialUpdates));
        expect(
          platform.published.last.snapshot.snapshotRevision,
          greaterThanOrEqualTo(
            platform.presented.single.publicSnapshot.snapshotRevision,
          ),
        );
      } else {
        expect(controller.failure, 'request_rejected');
        expect(platform.dismissed, hasLength(1));
      }
    },
  );
}
