import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/data/kiosk_api.dart';
import 'package:larenor/features/kiosk/domain/kiosk_models.dart';

Map<String, Object?> snapshotJson() => {
  'supported': true,
  'deviceOwner': true,
  'permitted': true,
  'lockState': 'none',
  'resumed': true,
  'focused': true,
  'eligibleWindow': true,
  'keyguardLocked': false,
  'powerMenuAllowed': true,
  'allowlistCount': 1,
  'actions': ['enter', 'removeApp'],
};
const token = 'native-one-use-0000000000000000';
KioskIntent intent() => KioskIntent(
  id: token,
  action: KioskAction.enter,
  snapshot: KioskSnapshot.fromChannel(snapshotJson()),
);
void main() {
  const channel = MethodChannel('test/larenor/kiosk');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('native contract sends action then opaque one-use token only; no PIN or arbitrary package', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'snapshot' => snapshotJson(),
        'prepare' => {
          'id': token,
          'action': 'enter',
          'snapshot': snapshotJson(),
        },
        'execute' => {
          'outcome': 'observed',
          'snapshot': {
            ...snapshotJson(),
            'lockState': 'locked',
            'actions': ['exit', 'removeApp'],
          },
        },
        _ => null,
      };
    });
    final api = AndroidKioskApi(channel: channel, isAndroid: true);
    await api.snapshot();
    final proposal = await api.prepare(KioskAction.enter);
    await api.execute(proposal);
    await api.cancel(proposal);
    expect(calls.map((v) => v.method), [
      'snapshot',
      'prepare',
      'execute',
      'cancel',
    ]);
    expect(calls[0].arguments, isNull);
    expect(calls[1].arguments, {'action': 'enter'});
    expect(calls[2].arguments, {'id': token});
    expect(calls.toString(), isNot(contains('1234')));
  });
  test('unsupported platform does not call native channel', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return null;
    });
    final api = AndroidKioskApi(channel: channel, isAndroid: false);
    expect((await api.snapshot()).supported, isFalse);
    await expectLater(
      api.prepare(KioskAction.enter),
      throwsA(isA<KioskException>()),
    );
    expect(calls, 0);
  });
  for (final code in ['expired', 'denied', 'busy']) {
    test(
      'native known rejection $code is typed and excludes server error details',
      () async {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(
            code: code,
            message: 'private device data',
            details: 'private',
          ),
        );
        await expectLater(
          AndroidKioskApi(channel: channel, isAndroid: true).execute(intent()),
          throwsA(
            isA<KioskException>().having(
              (e) => e.toString(),
              'safe',
              isNot(contains('private')),
            ),
          ),
        );
      },
    );
  }
  test(
    'unreadable native result after dispatch becomes uncertain, without retry',
    () async {
      var writes = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        writes++;
        return {'outcome': 'observed', 'snapshot': null};
      });
      final receipt = await AndroidKioskApi(
        channel: channel,
        isAndroid: true,
      ).execute(intent());
      expect(receipt.outcome, KioskOutcome.unknown);
      expect(writes, 1);
    },
  );
  test('unexpected native error after dispatch becomes uncertain, without raw exception text', () async {
    var writes = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      writes++;
      throw PlatformException(code: 'platform', message: 'private');
    });
    expect(
      (await AndroidKioskApi(
        channel: channel,
        isAndroid: true,
      ).execute(intent())).outcome,
      KioskOutcome.unknown,
    );
    expect(writes, 1);
  });
  test('unknown owner and lock state remain unknown instead of true/none', () {
    final snapshot = KioskSnapshot.fromChannel({
      ...snapshotJson(),
      'deviceOwner': null,
      'lockState': 'unknown',
      'powerMenuAllowed': null,
      'actions': [],
    });
    expect(snapshot.deviceOwner, isNull);
    expect(snapshot.lockState, KioskLockState.unknown);
    expect(snapshot.powerMenuAllowed, isNull);
  });
  for (final bad in <Map<String, Object?>>[
    {...snapshotJson(), 'extra': 'private'},
    {...snapshotJson()}..remove('permitted'),
    {...snapshotJson(), 'lockState': 'running'},
    {...snapshotJson(), 'deviceOwner': 'yes'},
    {...snapshotJson(), 'allowlistCount': -1},
    {...snapshotJson(), 'allowlistCount': 1.2},
    {...snapshotJson(), 'allowlistCount': 10001},
    {
      ...snapshotJson(),
      'actions': ['wipe'],
    },
    {
      ...snapshotJson(),
      'actions': ['enter', 'enter'],
    },
  ]) {
    test(
      'invalid bounded native schema is rejected ${bad.keys.join('/')} ${bad['allowlistCount']} ${bad['actions']}',
      () {
        expect(
          () => KioskSnapshot.fromChannel(bad),
          throwsA(isA<KioskException>()),
        );
      },
    );
  }
  test('proposal rejects action mismatch and nonopaque token', () {
    expect(
      () => KioskIntent.fromChannel({
        'id': token,
        'action': 'exit',
        'snapshot': snapshotJson(),
      }, KioskAction.enter),
      throwsA(isA<KioskException>()),
    );
    expect(
      () => KioskIntent.fromChannel({
        'id': 'tiny',
        'action': 'enter',
        'snapshot': snapshotJson(),
      }, KioskAction.enter),
      throwsA(isA<KioskException>()),
    );
  });
}
