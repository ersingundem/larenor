import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/home_session_controller.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/features/backup/data/captured_restore_access.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';

import '../../core/home_scope_fixture.dart';

class _Pin extends PinLockStore {
  String? value = '1234';
  Completer<String?>? pending;
  @override
  Future<String?> read() async =>
      pending == null ? value : await pending!.future;
}

void main() {
  for (final source in HomeSource.values) {
    test(
      'captured $source access survives intended disposal only for durable owner checks',
      () async {
        final h = ScopeHarness(source), pin = _Pin();
        final home = HomeSessionController(store: h.source, account: h.account);
        await h.account.initialize();
        await home.initialize();
        if (source == HomeSource.verifiedCore) await h.signIn();
        home.runtimeMounted(home.runtimeIdentity);
        var current = true;
        final access = await CapturedRestoreAccess.capture(
          home: home,
          sourceStore: h.source,
          sessionStore: h.store,
          pinStore: pin,
          expectedPin: '1234',
          isCurrent: () => current,
        );
        access.checkLive();
        expect(access.ownership['source'], source.name);
        if (source == HomeSource.verifiedCore) {
          expect((access.ownership['scope'] as Map)['userId'], 'one');
        }
        current = false;
        home.dispose();
        h.account.dispose();
        expect(access.checkLive, throwsA(isA<BackupException>()));
        await access.checkDurable();
        expect(access.toString(), isNot(contains('1234')));
        await h.socket.events.close();
      },
    );
  }
  for (final change in ['source', 'pin', 'readFailure', 'session']) {
    test('post-handoff durable $change cannot authorize writes', () async {
      final h = ScopeHarness(HomeSource.verifiedCore), pin = _Pin();
      final home = HomeSessionController(store: h.source, account: h.account);
      await h.account.initialize();
      await home.initialize();
      await h.signIn();
      home.runtimeMounted(home.runtimeIdentity);
      final access = await CapturedRestoreAccess.capture(
        home: home,
        sourceStore: h.source,
        sessionStore: h.store,
        pinStore: pin,
        expectedPin: '1234',
        isCurrent: () => true,
      );
      switch (change) {
        case 'source':
          h.source.value = HomeSource.directLocal;
        case 'pin':
          pin.value = '5678';
        case 'readFailure':
          h.source.readFails = true;
        case 'session':
          await h.store.write(null);
      }
      await expectLater(access.checkDurable(), throwsA(isA<BackupException>()));
      home.dispose();
      h.account.dispose();
      await h.socket.events.close();
    });
  }
  test(
    'source roundtrip cannot revive old live approval with same enum',
    () async {
      final h = ScopeHarness(HomeSource.directLocal), pin = _Pin();
      final home = HomeSessionController(store: h.source, account: h.account);
      await h.account.initialize();
      await home.initialize();
      home.runtimeMounted(home.runtimeIdentity);
      final access = await CapturedRestoreAccess.capture(
        home: home,
        sourceStore: h.source,
        sessionStore: h.store,
        pinStore: pin,
        expectedPin: '1234',
        isCurrent: () => true,
      );
      await home.choose(HomeSource.verifiedCore);
      await home.choose(HomeSource.directLocal);
      home.runtimeMounted(home.runtimeIdentity);
      expect(access.checkLive, throwsA(isA<BackupException>()));
      home.dispose();
      h.account.dispose();
      await h.socket.events.close();
    },
  );
  test('unverified Core never becomes a standalone Direct fallback', () async {
    final h = ScopeHarness(HomeSource.verifiedCore);
    await expectLater(
      CapturedRestoreAccess.capture(
        home: null,
        sourceStore: h.source,
        sessionStore: h.store,
        pinStore: _Pin(),
        expectedPin: '1234',
        isCurrent: () => true,
      ),
      throwsA(isA<BackupException>()),
    );
    expect(h.api.logins, 0);
    await h.socket.events.close();
  });
  test('late PIN read cannot establish a retired UI receipt', () async {
    final h = ScopeHarness(HomeSource.directLocal),
        pin = _Pin()..pending = Completer<String?>();
    var current = true;
    final result = CapturedRestoreAccess.capture(
      home: null,
      sourceStore: h.source,
      sessionStore: h.store,
      pinStore: pin,
      expectedPin: '1234',
      isCurrent: () => current,
    );
    final expected = expectLater(result, throwsA(isA<BackupException>()));
    current = false;
    pin.pending!.complete('1234');
    await expected;
    await h.socket.events.close();
  });
}
