import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late PinLockStore store;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    now = DateTime.utc(2026, 9, 5);
    store = PinLockStore(now: () => now);
  });

  test('five wrong attempts persist a pause across store recreation', () async {
    await store.save('1234');
    for (var i = 0; i < 4; i++) {
      expect((await store.verify('0000')).retryAfter, Duration.zero);
    }
    expect(
      (await store.verify('0000')).retryAfter,
      const Duration(seconds: 30),
    );
    final reopened = PinLockStore(now: () => now);
    expect((await reopened.verify('1234')).accepted, isFalse);
    now = now.add(const Duration(seconds: 30));
    expect((await reopened.verify('1234')).accepted, isTrue);
    expect((await reopened.verify('0000')).retryAfter, Duration.zero);
  });

  test(
    'concurrent attempts cannot bypass counting and pause escalates',
    () async {
      await store.save('1234');
      final results = await Future.wait(
        List.generate(10, (_) => store.verify('0')),
      );
      expect(results.where((r) => r.retryAfter == Duration.zero), hasLength(4));
      now = now.add(const Duration(seconds: 30));
      expect((await store.verify('0')).retryAfter, const Duration(seconds: 60));
    },
  );

  test('new PIN validation does not replace an existing valid PIN', () async {
    await store.save('1234');
    for (final pin in ['abc123', '123', '1234567890123', '1234\n']) {
      await expectLater(store.save(pin), throwsFormatException);
    }
    expect(await store.read(), '1234');
    await store.save('987654');
    expect((await store.verify('987654')).accepted, isTrue);
  });

  test('changing or removing PIN clears failed attempts', () async {
    await store.save('1234');
    for (var i = 0; i < 5; i++) {
      await store.verify('0');
    }
    await store.save('9876');
    expect((await store.verify('9876')).accepted, isTrue);
    await store.clear();
    expect(await store.read(), isNull);
  });

  test(
    'corrupt attempt state fails closed instead of granting access',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'settings_pin': '1234',
        'settings_pin_attempts': 'invalid',
      });
      await expectLater(store.verify('1234'), throwsFormatException);
    },
  );
}
