import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/shared/utils/foreground_poller.dart';

void main() {
  testWidgets(
    'slow reads never overlap; refreshes coalesce and disposal stops work',
    (tester) async {
      final pending = <Completer<void>>[];
      final poller = ForegroundPoller(
        interval: const Duration(seconds: 1),
        poll: () {
          final completer = Completer<void>();
          pending.add(completer);
          return completer.future;
        },
      )..start();
      await tester.pump(const Duration(seconds: 5));
      expect(pending, hasLength(1));
      poller.refresh();
      poller.refresh();
      pending.first.complete();
      await tester.pump();
      expect(pending, hasLength(2));
      poller.dispose();
      pending.last.complete();
      await tester.pump(const Duration(seconds: 5));
      expect(pending, hasLength(2));
    },
  );

  testWidgets('backgrounding pauses reads and resume refreshes immediately', (
    tester,
  ) async {
    var calls = 0;
    final poller = ForegroundPoller(
      interval: const Duration(seconds: 1),
      poll: () async {
        calls++;
      },
    )..start();
    await tester.pump();
    expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 5));
    expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 2);
    poller.dispose();
  });

  testWidgets('failed reads are handled and do not break the next interval', (
    tester,
  ) async {
    var calls = 0;
    var errors = 0;
    final poller = ForegroundPoller(
      interval: const Duration(seconds: 1),
      poll: () async {
        if (++calls == 1) throw StateError('offline');
      },
      onError: (_, _) => errors++,
    )..start();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(errors, 1);
    expect(calls, 2);
    expect(tester.takeException(), isNull);
    poller.dispose();
  });
}
