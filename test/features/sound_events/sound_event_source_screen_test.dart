import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/sound_events/data/core_sound_event_api.dart';
import 'package:larenor/features/sound_events/domain/sound_event_source_models.dart';
import 'package:larenor/features/sound_events/presentation/sound_event_source_screen.dart';

const _cameraId = '11111111111111111111111111111111';
const _roomId = '22222222222222222222222222222222';

final class _Api implements SoundSourceConfigurationApi {
  _Api(this.setup);
  SoundSourceSetup setup;
  int writes = 0;
  int discoveries = 0;
  bool discoveryFails = false;
  SoundSourceSetup? discovered;
  bool? lastConsent;

  @override
  Future<SoundSourceSetup> loadSourceSetup() async => setup;

  @override
  Future<SoundSourceSetup> discoverSourceSetup() async {
    discoveries++;
    if (discoveryFails) throw StateError('offline');
    return discovered ?? setup;
  }

  @override
  Future<SoundSourceSetup> configureSource({
    required SoundSourceSetup current,
    required SoundSourceChoice camera,
    required SoundSourceChoice room,
    required List<String> barkLabels,
    required List<String> noiseLabels,
    required bool consentGranted,
    required int retentionSeconds,
  }) async {
    writes++;
    expect(camera.id, _cameraId);
    expect(room.id, _roomId);
    expect(barkLabels, ['bark']);
    expect(noiseLabels, ['fire_alarm']);
    lastConsent = consentGranted;
    expect(retentionSeconds, 86400);
    setup = SoundSourceSetup(
      revision: current.revision + 1,
      discoveryVerified: false,
      configuration: SoundSourceConfiguration(
        revision: current.revision + 1,
        cameraResourceId: camera.id,
        cameraRevision: camera.revision,
        roomId: room.id,
        roomRevision: room.revision,
        labels: {'bark': barkLabels, 'noise': noiseLabels},
        consentGranted: consentGranted,
        retentionSeconds: retentionSeconds,
      ),
      cameras: current.cameras,
      rooms: current.rooms,
    );
    return setup;
  }
}

void main() {
  testWidgets('explicit consent saves only supported configured labels', (
    tester,
  ) async {
    final setup = SoundSourceSetup(
      revision: 0,
      discoveryVerified: true,
      configuration: null,
      cameras: const [
        SoundSourceChoice(
          id: _cameraId,
          revision: 7,
          label: 'Front door',
          audioLabels: ['bark', 'fire_alarm', 'speech'],
        ),
      ],
      rooms: const [
        SoundSourceChoice(
          id: _roomId,
          revision: 3,
          label: 'Entry',
          audioLabels: [],
        ),
      ],
    );
    final api = _Api(setup);
    SoundSourceSetup? saved;
    await tester.pumpWidget(
      CupertinoApp(
        home: SoundEventSourceScreen(
          api: api,
          setup: setup,
          onConfigured: (value) => saved = value,
          onCancel: null,
        ),
      ),
    );
    expect(find.textContaining('Raw audio'), findsOneWidget);
    expect(find.byKey(const ValueKey('sound-source-save')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sound-source-consent')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sound-source-save')));
    await tester.pumpAndSettle();
    expect(api.writes, 1);
    expect(api.lastConsent, isTrue);
    expect(saved?.configuration?.consentGranted, isTrue);
  });

  testWidgets('existing source can revoke consent', (tester) async {
    final setup = SoundSourceSetup(
      revision: 4,
      discoveryVerified: false,
      configuration: const SoundSourceConfiguration(
        revision: 4,
        cameraResourceId: _cameraId,
        cameraRevision: 7,
        roomId: _roomId,
        roomRevision: 3,
        labels: {
          'bark': ['bark'],
          'noise': ['fire_alarm'],
        },
        consentGranted: true,
        retentionSeconds: 86400,
      ),
      cameras: const [
        SoundSourceChoice(
          id: _cameraId,
          revision: 7,
          label: 'Front door',
          audioLabels: ['bark', 'fire_alarm'],
        ),
      ],
      rooms: const [
        SoundSourceChoice(
          id: _roomId,
          revision: 3,
          label: 'Entry',
          audioLabels: [],
        ),
      ],
    );
    final api = _Api(setup);
    api.discoveryFails = true;
    SoundSourceSetup? saved;
    await tester.pumpWidget(
      CupertinoApp(
        home: SoundEventSourceScreen(
          api: api,
          setup: setup,
          onConfigured: (value) => saved = value,
          onCancel: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.discoveries, 1);
    expect(find.textContaining('still revoke consent'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sound-source-consent')));
    await tester.pump();
    expect(find.text('Revoke consent'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sound-source-save')));
    await tester.pumpAndSettle();
    expect(api.writes, 1);
    expect(api.lastConsent, isFalse);
    expect(saved?.configuration?.consentGranted, isFalse);
  });

  testWidgets('revoked source requires fresh discovery before re-enabling', (
    tester,
  ) async {
    final local = SoundSourceSetup(
      revision: 5,
      discoveryVerified: false,
      configuration: const SoundSourceConfiguration(
        revision: 5,
        cameraResourceId: _cameraId,
        cameraRevision: 7,
        roomId: _roomId,
        roomRevision: 3,
        labels: {
          'bark': ['bark'],
          'noise': ['fire_alarm'],
        },
        consentGranted: false,
        retentionSeconds: 86400,
      ),
      cameras: const [
        SoundSourceChoice(
          id: _cameraId,
          revision: 7,
          label: 'Configured camera',
          audioLabels: ['bark', 'fire_alarm'],
        ),
      ],
      rooms: const [
        SoundSourceChoice(
          id: _roomId,
          revision: 3,
          label: 'Configured room',
          audioLabels: [],
        ),
      ],
    );
    final verified = SoundSourceSetup(
      revision: 5,
      discoveryVerified: true,
      configuration: local.configuration,
      cameras: const [
        SoundSourceChoice(
          id: _cameraId,
          revision: 7,
          label: 'Front door',
          audioLabels: ['bark', 'fire_alarm'],
        ),
      ],
      rooms: const [
        SoundSourceChoice(
          id: _roomId,
          revision: 3,
          label: 'Entry',
          audioLabels: [],
        ),
      ],
    );
    final api = _Api(local)..discovered = verified;
    SoundSourceSetup? saved;
    await tester.pumpWidget(
      CupertinoApp(
        home: SoundEventSourceScreen(
          api: api,
          setup: local,
          onConfigured: (value) => saved = value,
          onCancel: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.discoveries, 1);
    expect(find.text('Sources verified'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sound-source-consent')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sound-source-save')));
    await tester.pumpAndSettle();
    expect(api.writes, 1);
    expect(saved?.configuration?.consentGranted, isTrue);
  });
}
