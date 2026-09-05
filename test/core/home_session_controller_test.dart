import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';

import 'home_scope_fixture.dart';

class _DelayedRead extends SourceMemory {
  _DelayedRead() : super(HomeSource.directLocal);
  final reading = Completer<HomeSource>();
  @override
  Future<HomeSource> read() => reading.future;
}

void main() {
  test(
    'disposing a pending read does not notify or restore an account',
    () async {
      final h = ScopeHarness(HomeSource.directLocal);
      final store = _DelayedRead();
      final controller = HomeSessionController(
        store: store,
        account: h.account,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      final initialize = controller.initialize();
      expect(controller.busy, isTrue);
      controller.dispose();
      final before = notifications;
      store.reading.complete(HomeSource.verifiedCore);
      await initialize;
      expect(notifications, before);
      expect(h.store.reads, 0);
      h.account.dispose();
      await h.socket.events.close();
    },
  );

  test(
    'disposing a pending source write cannot publish to a replacement runtime',
    () async {
      final h = ScopeHarness(HomeSource.directLocal);
      final controller = HomeSessionController(
        store: h.source,
        account: h.account,
      );
      await controller.initialize();
      controller.runtimeMounted(controller.runtimeIdentity);
      final epoch = controller.interaction.epoch;
      h.source.pendingWrite = Completer<void>();
      final write = controller.choose(HomeSource.verifiedCore);
      expect(controller.interaction.active, isFalse);
      expect(controller.interaction.epoch, greaterThan(epoch));
      await controller.choose(HomeSource.directLocal);
      expect(h.source.writes, 1);
      controller.dispose();
      h.source.pendingWrite!.complete();
      await write;
      expect(h.store.reads, 0);
      h.account.dispose();
      await h.socket.events.close();
    },
  );

  test('wrong runtime identity cannot reactivate the retiring home', () async {
    final h = ScopeHarness(HomeSource.directLocal);
    final controller = HomeSessionController(
      store: h.source,
      account: h.account,
    );
    await controller.initialize();
    controller.runtimeMounted('wrong');
    expect(controller.interaction.active, isFalse);
    controller.runtimeMounted(controller.runtimeIdentity);
    expect(controller.interaction.active, isTrue);
    controller.dispose();
    h.account.dispose();
    await h.socket.events.close();
  });

  test('explicit retry after failed read remains fail closed until persistence succeeds', () async {
    final h = ScopeHarness(HomeSource.directLocal);
    h.source.readFails = true;
    final controller = HomeSessionController(
      store: h.source,
      account: h.account,
    );
    await controller.initialize();
    expect(controller.failure, 'source_read_failed');
    expect(controller.usesLocalHome, isFalse);
    h.source.writeFails = true;
    await controller.choose(HomeSource.directLocal);
    expect(controller.failure, 'source_write_failed');
    expect(controller.usesLocalHome, isFalse);
    h.source.writeFails = false;
    await controller.choose(HomeSource.directLocal);
    expect(controller.failure, isNull);
    expect(controller.usesLocalHome, isTrue);
    expect(h.store.reads, 0);
    controller.dispose();
    h.account.dispose();
    await h.socket.events.close();
  });
}
