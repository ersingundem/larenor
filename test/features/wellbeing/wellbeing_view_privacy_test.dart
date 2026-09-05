import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/wellbeing/data/wellbeing_view_privacy.dart';
import 'package:larenor/features/wellbeing/domain/wellbeing_models.dart';

class _Bridge implements WellbeingViewPrivacyBridge {
  Completer<void>? protectGate;
  final calls = <bool>[];
  @override
  Future<void> setPrivateView(bool enabled) async {
    calls.add(enabled);
    if (enabled) await protectGate?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an expired acquire is rejected before exposure and releases protection',
    () async {
      final bridge = _Bridge()..protectGate = Completer();
      final privacy = WellbeingViewPrivacy(bridge);
      var current = true;
      final acquire = privacy.acquire(Object(), isCurrent: () => current);
      final check = expectLater(acquire, throwsA(isA<WellbeingException>()));
      await Future<void>.delayed(Duration.zero);
      current = false;
      bridge.protectGate!.complete();
      await check;
      expect(bridge.calls, [true, false]);
      privacy.dispose();
    },
  );

  test('old-route release cannot unprotect the new private owner', () async {
    final bridge = _Bridge();
    final privacy = WellbeingViewPrivacy(bridge);
    final old = Object(), next = Object();
    await privacy.acquire(old, isCurrent: () => true);
    await privacy.acquire(next, isCurrent: () => true);
    await privacy.release(old);
    expect(bridge.calls, [true, true]);
    await privacy.release(next);
    expect(bridge.calls, [true, true, false]);
    privacy.dispose();
  });

  test(
    'cancelled replacement cannot unprotect the still-owned private view',
    () async {
      final bridge = _Bridge();
      final privacy = WellbeingViewPrivacy(bridge);
      final owner = Object();
      await privacy.acquire(owner, isCurrent: () => true);
      var current = true;
      bridge.protectGate = Completer();
      final pending = privacy.acquire(Object(), isCurrent: () => current);
      final check = expectLater(pending, throwsA(isA<WellbeingException>()));
      await Future<void>.delayed(Duration.zero);
      current = false;
      bridge.protectGate!.complete();
      await check;
      expect(bridge.calls, [true, true]);
      await privacy.release(owner);
      expect(bridge.calls, [true, true, false]);
      privacy.dispose();
    },
  );

  testWidgets(
    'pending background release is flushed only after a foreground frame',
    (tester) async {
      final bridge = _Bridge();
      final privacy = WellbeingViewPrivacy(bridge);
      final owner = Object();
      await privacy.acquire(owner, isCurrent: () => true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await privacy.release(owner);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(bridge.calls, [true, false]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(bridge.calls, [true, false, false]);
      privacy.dispose();
    },
  );
}
