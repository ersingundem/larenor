import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/web_panel/data/web_panel_data.dart';

class Api extends WebPanelDataApi {
  final calls = <String>[];
  Completer<void>? cookies;
  bool fail = false;
  @override
  Future<void> clearCookies() async {
    calls.add('cookies');
    if (cookies != null) await cookies!.future;
  }

  @override
  Future<void> clearLocalStorage() async {
    calls.add('storage');
    if (fail) throw StateError('sensitive-native-payload');
  }

  @override
  Future<void> clearCache() async {
    calls.add('cache');
  }
}

void main() {
  test(
    'retirements from already-disposed views must settle before cookies clear',
    () async {
      final api = Api();
      final coordinator = WebPanelDataCoordinator(api: api);
      final lateBlank = Completer<void>();
      coordinator.retire(() => lateBlank.future);
      final clear = coordinator.clear(isCurrent: () => true);
      await Future<void>.delayed(Duration.zero);
      expect(api.calls, isEmpty);
      expect(coordinator.blocked, true);
      lateBlank.complete();
      expect(await clear, true);
      expect(api.calls, ['cookies', 'storage', 'cache']);
      coordinator.dispose();
    },
  );
  test(
    'failed detached renderer blocks clear until its retirement can succeed',
    () async {
      final api = Api();
      final coordinator = WebPanelDataCoordinator(api: api);
      var failing = true;
      coordinator.retire(() async {
        if (failing) throw StateError('native failure');
      });
      await Future<void>.delayed(Duration.zero);
      expect(await coordinator.clear(isCurrent: () => true), false);
      expect(api.calls, isEmpty);
      expect(coordinator.blocked, true);
      failing = false;
      expect(await coordinator.clear(isCurrent: () => true), true);
      coordinator.dispose();
    },
  );
  test(
    'blank all panels before global clear and enforce single flight',
    () async {
      final api = Api();
      final coordinator = WebPanelDataCoordinator(api: api);
      final retired = Completer<void>();
      coordinator.register(() {
        api.calls.add('retire');
        return retired.future;
      });
      final first = coordinator.clear(isCurrent: () => true);
      expect(coordinator.blocked, true);
      expect(api.calls, ['retire']);
      expect(await coordinator.clear(isCurrent: () => true), false);
      retired.complete();
      expect(await first, true);
      expect(api.calls, ['retire', 'cookies', 'storage', 'cache']);
      expect(coordinator.blocked, false);
      coordinator.dispose();
    },
  );
  test(
    'cancelled permission does not clear; cancellation in-flight stays paused',
    () async {
      final api = Api()..cookies = Completer<void>();
      final coordinator = WebPanelDataCoordinator(api: api);
      var current = false;
      expect(await coordinator.clear(isCurrent: () => current), false);
      expect(api.calls, isEmpty);
      current = true;
      final result = coordinator.clear(isCurrent: () => current);
      await Future<void>.delayed(Duration.zero);
      current = false;
      api.cookies!.complete();
      expect(await result, false);
      expect(coordinator.blocked, true);
      expect(api.calls, ['cookies']);
      coordinator.dispose();
    },
  );
  test(
    'partial failure remains paused until new explicit successful retry',
    () async {
      final api = Api()..fail = true;
      final coordinator = WebPanelDataCoordinator(api: api);
      expect(await coordinator.clear(isCurrent: () => true), false);
      expect(coordinator.blocked, true);
      api.fail = false;
      expect(await coordinator.clear(isCurrent: () => true), true);
      expect(coordinator.blocked, false);
      coordinator.dispose();
    },
  );
  test('timeout cannot permit retry or new renderer until late native call settles', () {
    fakeAsync((clock) {
      final api = Api()..cookies = Completer<void>();
      final coordinator = WebPanelDataCoordinator(api: api);
      bool? result;
      coordinator.clear(isCurrent: () => true).then((v) => result = v);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 21));
      clock.flushMicrotasks();
      expect(result, false);
      expect(coordinator.running, true);
      expect(coordinator.blocked, true);
      coordinator.clear(isCurrent: () => true);
      clock.flushMicrotasks();
      expect(api.calls, ['cookies']);
      api.cookies!.complete();
      clock.flushMicrotasks();
      expect(coordinator.running, false);
      expect(coordinator.blocked, true);
      coordinator.clear(isCurrent: () => true);
      clock.flushMicrotasks();
      expect(coordinator.blocked, false);
      coordinator.dispose();
    });
  });
}
