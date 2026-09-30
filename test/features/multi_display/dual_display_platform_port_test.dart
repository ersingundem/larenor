import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/multi_display/data/dual_display_platform_port.dart';
import 'package:larenor/features/multi_display/domain/dual_display_session.dart';

PublicCoreStatusSnapshot snapshot([int revision = 101]) =>
    PublicCoreStatusSnapshot(
      snapshotRevision: revision,
      observedAtMs: 1000,
      expiresAtMs: 16000,
      systemLoadPercent: 10,
      processMemoryMiB: 128,
      dataDiskFreeBytes: 400,
      dataDiskTotalBytes: 1000,
      processUptimeSeconds: 30,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ersingundem.larenor/dual_display_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'native topology and exact presentation receipt remain bounded',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'snapshot') {
          return {
            'revision': 7,
            'surfaces': [
              {
                'displayId': 0,
                'generation': 3,
                'kind': 'primary',
                'widthPixels': 1600,
                'heightPixels': 2560,
                'densityDpi': 320,
                'securePresentation': true,
              },
              {
                'displayId': 4,
                'generation': 5,
                'kind': 'external',
                'widthPixels': 1920,
                'heightPixels': 1080,
                'densityDpi': 160,
                'securePresentation': true,
              },
            ],
          };
        }
        if (call.method == 'present') {
          final args = Map<String, Object?>.from(call.arguments as Map);
          expect(args.keys, {
            'sessionId',
            'topologyRevision',
            'displayId',
            'displayGeneration',
            'routeId',
            'publicSnapshot',
          });
          expect((args['publicSnapshot']! as Map).keys, {
            'schemaVersion',
            'snapshotRevision',
            'observedAtMs',
            'expiresAtMs',
            'serviceState',
            'apiVersion',
            'systemLoadPercent',
            'processMemoryMiB',
            'dataDiskFreeBytes',
            'dataDiskTotalBytes',
            'processUptimeSeconds',
          });
          return {
            for (final entry in args.entries)
              if (entry.key != 'publicSnapshot') entry.key: entry.value,
            'attached': true,
          };
        }
        if (call.method == 'publishPublicSnapshot') {
          final args = Map<String, Object?>.from(call.arguments as Map);
          final public = Map<String, Object?>.from(
            args['publicSnapshot']! as Map,
          );
          return {
            'sessionId': args['sessionId'],
            'displayId': args['displayId'],
            'snapshotRevision': public['snapshotRevision'],
            'accepted': true,
          };
        }
        if (call.method == 'dismiss') return null;
        throw PlatformException(code: 'unexpected');
      });

      final port = MethodChannelSecondaryDisplayPort(channel: channel);
      final topology = await port.snapshot();
      expect(topology.revision, 7);
      expect(topology.surfaces, hasLength(2));
      final secondary = topology.externalById(4)!;
      final request = SecondaryPresentationRequest(
        sessionId: 'display-session-1-7-4',
        topologyRevision: 7,
        display: secondary,
        routeId: 'core.status',
        publicSnapshot: snapshot(),
      );
      expect(await port.present(request), isA<SecondaryPresentationReceipt>());
      await port.publishPublicSnapshot(
        SecondaryPublicSnapshotUpdate(
          sessionId: request.sessionId,
          displayId: 4,
          snapshot: snapshot(102),
        ),
      );
      await port.dismiss(
        const SecondaryDismissal(
          sessionId: 'display-session-1-7-4',
          displayId: 4,
        ),
      );
      expect(calls.map((call) => call.method), [
        'snapshot',
        'present',
        'publishPublicSnapshot',
        'dismiss',
      ]);
    },
  );

  test('malformed or private native responses fail closed', () async {
    final port = MethodChannelSecondaryDisplayPort(channel: channel);
    for (final payload in <Object?>[
      null,
      {'revision': 7, 'surfaces': []},
      {
        'revision': 7,
        'surfaces': [
          {
            'displayId': 0,
            'generation': 1,
            'kind': 'primary',
            'widthPixels': 1600,
            'heightPixels': 2560,
            'densityDpi': 320,
            'securePresentation': true,
            'token': 'must-not-cross',
          },
        ],
      },
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => payload);
      await expectLater(port.snapshot(), throwsA(isA<DualDisplayException>()));
    }

    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'sessionId': 'foreign-session',
        'displayId': 4,
        'displayGeneration': 5,
        'topologyRevision': 7,
        'routeId': 'core.status',
        'attached': true,
      },
    );
    await expectLater(
      port.present(
        SecondaryPresentationRequest(
          sessionId: 'display-session-1-7-4',
          topologyRevision: 7,
          display: DisplaySurface(
            displayId: 4,
            generation: 5,
            kind: DisplayKind.external,
            widthPixels: 1920,
            heightPixels: 1080,
            densityDpi: 160,
            securePresentation: true,
          ),
          routeId: 'core.status',
          publicSnapshot: snapshot(),
        ),
      ),
      throwsA(isA<DualDisplayException>()),
    );
  });
}
