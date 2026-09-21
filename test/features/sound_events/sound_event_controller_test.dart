import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/sound_events/data/sound_event_controller.dart';
import 'package:larenor/features/sound_events/domain/sound_event_models.dart';

void main() {
  test('acknowledgement is verified by an exact refreshed readback', () async {
    final api = _Api();
    final controller = SoundEventController(
      api: api,
      authority: authority(),
      isCurrent: () => true,
    );
    await controller.load();
    expect(controller.state, SoundEventViewState.ready);
    await controller.acknowledge(controller.snapshot!.events.single);
    expect(controller.state, SoundEventViewState.verified);
    expect(controller.snapshot!.events.single.acknowledged, isTrue);
    expect(api.ackCalls, 1);
    controller.dispose();
  });

  test(
    'late response after route retirement clears private event state',
    () async {
      final pending = Completer<SoundEventSnapshot>();
      final api = _Api(loadResult: pending.future);
      var current = true;
      final controller = SoundEventController(
        api: api,
        authority: authority(),
        isCurrent: () => current,
      );
      final load = controller.load();
      current = false;
      controller.setInteractive(false);
      pending.complete(snapshot(acknowledged: false));
      await load;
      expect(controller.state, SoundEventViewState.stale);
      expect(controller.snapshot, isNull);
      controller.dispose();
    },
  );
}

SoundEventAuthority authority() => const SoundEventAuthority(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: '33333333333333333333333333333333',
  sessionFamilyId: '44444444444444444444444444444444',
  accountRevision: 1,
  repositoryRevision: 1,
  canRead: true,
  canAcknowledge: true,
);

SoundEventSnapshot snapshot({required bool acknowledged}) => SoundEventSnapshot(
  authority: authority().withRepositoryRevision(acknowledged ? 2 : 1),
  repositoryRevision: acknowledged ? 2 : 1,
  events: [
    SoundEventItem(
      eventId: '88888888888888888888888888888888',
      roomId: '55555555555555555555555555555555',
      deviceId: '66666666666666666666666666666666',
      className: 'bark',
      confidence: .91,
      observedAt: DateTime.fromMillisecondsSinceEpoch(10000, isUtc: true),
      retentionExpiresAt: DateTime.fromMillisecondsSinceEpoch(
        10000000000000,
        isUtc: true,
      ),
      eventRevision: acknowledged ? 2 : 1,
      acknowledged: acknowledged,
      automationVerified: true,
    ),
  ],
);

final class _Api implements SoundEventApi {
  _Api({this.loadResult});
  final Future<SoundEventSnapshot>? loadResult;
  int ackCalls = 0;
  bool acknowledged = false;

  @override
  Future<SoundEventSnapshot> load(
    SoundEventAuthority expected,
    SoundEventFilter filter,
  ) => loadResult ?? Future.value(snapshot(acknowledged: acknowledged));

  @override
  Future<SoundEventAcknowledgement> acknowledge(
    SoundEventAuthority expected,
    SoundEventSnapshot current,
    SoundEventItem event,
  ) async {
    ackCalls++;
    acknowledged = true;
    return SoundEventAcknowledgement(
      requestId: '99999999999999999999999999999999',
      eventId: event.eventId,
      accountId: expected.accountId,
      sessionFamilyId: expected.sessionFamilyId,
      repositoryRevision: 2,
      eventRevision: 2,
      acknowledged: true,
    );
  }
}
