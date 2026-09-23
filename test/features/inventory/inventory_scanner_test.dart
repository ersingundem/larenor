import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/inventory/data/inventory_scanner.dart';

final class FakeScannerSession implements InventoryScannerSession {
  final codes = StreamController<String>.broadcast();
  final failures = StreamController<InventoryCameraFailure>.broadcast();
  int closes = 0;
  Completer<void>? closeGate;
  @override
  Stream<String> get values => codes.stream;
  @override
  Stream<InventoryCameraFailure> get errors => failures.stream;
  @override
  Widget preview() => const SizedBox(key: ValueKey('fake-camera'));
  @override
  Future<void> close() async {
    closes++;
    await closeGate?.future;
  }
}

final class FakeScannerPlatform implements InventoryScannerPlatform {
  final sessions = <FakeScannerSession>[];
  @override
  InventoryScannerSession create() {
    final value = FakeScannerSession();
    sessions.add(value);
    return value;
  }
}

final class ThrowingScannerPlatform implements InventoryScannerPlatform {
  @override
  InventoryScannerSession create() => throw StateError('camera unavailable');
}

void main() {
  test(
    'unacknowledged camera close blocks reopen and never publishes old scan',
    () async {
      final platform = FakeScannerPlatform();
      final values = <String>[];
      final controller = InventoryScannerController(
        platform: platform,
        isCurrent: () => true,
        onValue: values.add,
        closeTimeout: const Duration(milliseconds: 10),
      );
      await controller.open();
      final first = platform.sessions.single
        ..closeGate = Completer<void>()
        ..codes.add('old');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(values, isEmpty);
      expect(controller.canOpen, isFalse);
      await controller.open();
      expect(platform.sessions, hasLength(1));

      first.closeGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.canOpen, isTrue);
      expect(values, isEmpty);
      await controller.open();
      expect(platform.sessions, hasLength(2));
    },
  );

  test(
    'camera creation failure closes safely and keeps manual entry',
    () async {
      final controller = InventoryScannerController(
        platform: ThrowingScannerPlatform(),
        isCurrent: () => true,
        onValue: (_) {},
      );

      await controller.open();

      expect(controller.opened, isFalse);
      expect(controller.failure, InventoryCameraFailure.unavailable);
      expect(controller.manualEntryAvailable, isTrue);
    },
  );

  test(
    'permission denial closes camera and preserves manual fallback',
    () async {
      final platform = FakeScannerPlatform();
      final controller = InventoryScannerController(
        platform: platform,
        isCurrent: () => true,
        onValue: (_) {},
      );
      await controller.open();
      platform.sessions.single.failures.add(
        InventoryCameraFailure.permissionDenied,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.opened, isFalse);
      expect(controller.failure, InventoryCameraFailure.permissionDenied);
      expect(controller.manualEntryAvailable, isTrue);
      expect(platform.sessions.single.closes, 1);
    },
  );

  test(
    'background rotation and authority change close reader permanently',
    () async {
      var current = true;
      final platform = FakeScannerPlatform();
      final values = <String>[];
      final controller = InventoryScannerController(
        platform: platform,
        isCurrent: () => current,
        onValue: values.add,
      );
      await controller.open();
      await controller.onLifecycle(AppLifecycleState.paused);
      expect(platform.sessions[0].closes, 1);
      await controller.onLifecycle(AppLifecycleState.resumed);
      await controller.open();
      await controller.onRotation();
      expect(platform.sessions[1].closes, 1);
      await controller.open();
      current = false;
      controller.synchronizeAuthority();
      platform.sessions[2].codes.add('late');
      await Future<void>.delayed(Duration.zero);
      expect(platform.sessions[2].closes, 1);
      expect(values, isEmpty);
      expect(controller.canOpen, isFalse);
    },
  );

  test(
    'first current scan closes one flight and ignores later values',
    () async {
      final platform = FakeScannerPlatform();
      final values = <String>[];
      final controller = InventoryScannerController(
        platform: platform,
        isCurrent: () => true,
        onValue: values.add,
      );
      await controller.open();
      final session = platform.sessions.single;
      session.codes.add('first');
      session.codes.add('second');
      await Future<void>.delayed(Duration.zero);
      expect(values, ['first']);
      expect(session.closes, 1);
      expect(controller.opened, isFalse);
    },
  );
}
