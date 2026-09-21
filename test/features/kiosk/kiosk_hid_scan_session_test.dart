import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/domain/kiosk_hid_scan_session.dart';

void main() {
  final start = DateTime.utc(2026, 9, 21);

  test(
    'only explicit foreground session captures bounded printable HID data',
    () {
      final session = KioskHidScanSession();
      session.feed('A', start);
      expect(session.state, HidScanState.inactive);
      session.start(start);
      for (final char in 'ABC-123'.split('')) {
        session.feed(char, start.add(const Duration(milliseconds: 10)));
      }
      session.finish(start.add(const Duration(milliseconds: 20)));
      expect(session.state, HidScanState.captured);
      expect(session.length, 7);
      expect(session.reviewedValue, isNull);
      session.reveal();
      expect(session.reviewedValue, 'ABC-123');
      session.stop();
      expect(session.reviewedValue, isNull);
      expect(session.length, 0);
    },
  );

  test('control/paste/oversize fail closed and never execute scan content', () {
    final session = KioskHidScanSession();
    session.start(start);
    session.feed('javascript:alert(1)', start);
    expect(session.state, HidScanState.invalid);
    expect(session.length, 0);
    session.start(start);
    for (var index = 0; index < 129; index++) {
      session.feed('x', start);
    }
    expect(session.state, HidScanState.tooLong);
    expect(session.length, 0);
    session.start(start);
    session.feed('\n', start);
    expect(session.state, HidScanState.invalid);
  });

  test('duplicate and missing reader timeout are bounded and memory-only', () {
    final session = KioskHidScanSession();
    session.start(start);
    for (final char in 'CODE-1'.split('')) {
      session.feed(char, start);
    }
    session.finish(start);
    session.start(start.add(const Duration(milliseconds: 100)));
    for (final char in 'CODE-1'.split('')) {
      session.feed(char, start.add(const Duration(milliseconds: 100)));
    }
    session.finish(start.add(const Duration(milliseconds: 100)));
    expect(session.state, HidScanState.duplicate);
    expect(session.reviewedValue, isNull);
    session.start(start.add(const Duration(seconds: 5)));
    session.feed('A', start.add(const Duration(seconds: 5)));
    session.expire(start.add(const Duration(seconds: 21)));
    expect(session.state, HidScanState.expired);
    expect(session.length, 0);
  });
}
