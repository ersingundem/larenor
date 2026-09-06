import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/settings/providers/settings_providers.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_resource_admin_fixture.dart';

VoidCallback held(WidgetTester tester, String key) =>
    tester.widget<CupertinoButton>(adminKey(key)).onPressed!;
Future<void> draft(WidgetTester tester) async {
  await adminPress(tester, 'home-resource-admin-create');
  await tester.enterText(adminKey('home-resource-label'), 'Private draft');
  await tester.enterText(adminKey('home-resource-order'), '7');
}

Future<void> lose(
  WidgetTester tester,
  ResourceAdminHarness h,
  String loss,
) async {
  switch (loss) {
    case 'window':
      h.window.add(
        const WindowPolicySnapshot(
          supported: true,
          isResumed: true,
          hasWindowFocus: false,
          reason: WindowRestrictionReason.noFocus,
        ),
      );
    case 'native':
      tester.binding.handleViewFocusChanged(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ViewFocusState.unfocused,
          direction: ViewFocusDirection.undefined,
        ),
      );
    case 'background':
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    case 'interaction':
      h.home(tester).interaction.setActive(false);
    case 'route':
      unawaited(
        Navigator.of(tester.element(adminKey('home-resource-admin'))).push(
          CupertinoPageRoute<void>(
            builder: (_) => const CupertinoPageScaffold(child: Text('Covered')),
          ),
        ),
      );
    case 'dispose':
      await tester.pumpWidget(const SizedBox.shrink());
    case 'source':
      h.source.writeFails = true;
      await h.home(tester).choose(HomeSource.directLocal);
    case 'logout':
      await h.account.signOut();
    case 'role':
      h.role = 'member';
      h.now = h.account.session!.expiresAt;
      await h.account.ensureSession();
    case 'expiry':
      h.now = h.account.session!.expiresAt;
      await tester.pump(const Duration(hours: 1));
  }
  await flush(tester);
}

class FailingPinRead extends PinLockStore {
  bool fail = false;
  @override
  Future<String?> read() async {
    if (fail) throw StateError('private-pin-failure');
    return super.read();
  }
}

void main() {
  for (final pending in [false, true]) {
    testWidgets(
      'real PIN store read error rejects preframe ${pending ? 'response' : 'save'} and permits explicit recovered reload',
      (tester) async {
        final h = ResourceAdminHarness(pinStore: FailingPinRead());
        // Use the exact store injected into the actual SettingsGate provider.
        final injected = h.pinStore! as FailingPinRead;
        await openAdmin(tester, h);
        await draft(tester);
        final callback = held(tester, 'home-resource-save');
        final late = Completer<http.Response>();
        if (pending) {
          h.pendingMutation = late;
          await adminPress(tester, 'home-resource-save');
        }
        final container = h.runtime(tester);
        injected.fail = true;
        container.invalidate(pinLockProvider);
        try {
          await container.read(pinLockProvider.future);
        } catch (_) {}
        expect(container.read(pinLockProvider).hasError, isTrue);
        if (pending) {
          late.complete(
            h.json({
              'error': {'code': 'unauthorized'},
            }, 401),
          );
          h.pendingMutation = null;
        } else {
          callback();
        }
        await flush(tester);
        expect(h.mutations.length, pending ? 1 : 0);
        expect(h.account.session, isNotNull);
        expect(find.text('Private draft'), findsNothing);
        expect(find.text('private-pin-failure'), findsNothing);
        injected.fail = false;
        container.invalidate(pinLockProvider);
        await container.read(pinLockProvider.future);
        await flush(tester);
        await draft(tester);
        callback();
        await flush(tester);
        expect(h.mutations.length, pending ? 1 : 0);
        await adminPress(tester, 'home-resource-save');
        expect(h.mutations.length, pending ? 2 : 1);
      },
    );
  }

  testWidgets(
    'removing PIN retires old form and opens a fresh no-PIN admin flow',
    (tester) async {
      final h = ResourceAdminHarness();
      await openAdmin(tester, h, pin: '1234');
      await draft(tester);
      final callback = held(tester, 'home-resource-save');
      await h.runtime(tester).read(pinLockProvider.notifier).clearPin();
      callback();
      await flush(tester);
      expect(h.mutations, isEmpty);
      expect(find.text('Private draft'), findsNothing);
      await draft(tester);
      callback();
      await flush(tester);
      expect(h.mutations, isEmpty);
      await adminPress(tester, 'home-resource-save');
      expect(h.mutations.length, 1);
    },
  );

  for (final boundary in ['pin-loading', 'pin-rotation', 'root-route']) {
    for (final pending in [false, true]) {
      testWidgets(
        '$boundary rejects preframe ${pending ? 'reply' : 'held save'}',
        (tester) async {
          final h = ResourceAdminHarness();
          await openAdmin(tester, h, pin: '1234');
          await draft(tester);
          final callback = held(tester, 'home-resource-save');
          final late = Completer<http.Response>();
          if (pending) {
            h.pendingMutation = late;
            await adminPress(tester, 'home-resource-save');
          }
          final container = h.runtime(tester);
          if (boundary == 'pin-loading') {
            container.invalidate(pinLockProvider);
            expect(container.read(pinLockProvider).isLoading, isTrue);
          }
          if (boundary == 'pin-rotation') {
            await container.read(pinLockProvider.notifier).setPin('5678');
          }
          if (boundary == 'root-route') {
            unawaited(
              Navigator.of(
                tester.element(adminKey('home-resource-admin')),
                rootNavigator: true,
              ).push(
                CupertinoPageRoute<void>(
                  builder: (_) =>
                      const CupertinoPageScaffold(child: Text('Root covered')),
                ),
              ),
            );
          }
          // Deliberately no pump: old nested page still exists in this frame.
          if (pending) {
            late.complete(
              h.json({
                'error': {'code': 'unauthorized'},
              }, 401),
            );
            h.pendingMutation = null;
          } else {
            callback();
          }
          await flush(tester);
          expect(h.mutations.length, pending ? 1 : 0);
          expect(h.account.session, isNotNull);
          expect(adminKey('home-resource-mutation-saved'), findsNothing);
          expect(find.text('Private draft'), findsNothing);
        },
      );
    }
  }

  for (final loss in [
    'window',
    'native',
    'background',
    'interaction',
    'route',
    'dispose',
    'source',
    'logout',
    'role',
    'expiry',
  ]) {
    for (final mode in ['save', 'delete']) {
      testWidgets('$mode held callback retires on $loss without dispatch', (
        tester,
      ) async {
        final h = ResourceAdminHarness();
        await openAdmin(tester, h);
        if (mode == 'save') {
          await draft(tester);
        } else {
          await adminPress(
            tester,
            'home-resource-delete-${h.records.first['ref']['id']}',
          );
        }
        final callback = held(
          tester,
          mode == 'save'
              ? 'home-resource-save'
              : 'home-resource-confirm-delete',
        );
        await lose(tester, h, loss);
        callback();
        await flush(tester);
        expect(h.mutations, isEmpty);
        expect(find.text('Private draft'), findsNothing);
        expect(h.haReads, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final loss in [
    'window',
    'native',
    'background',
    'interaction',
    'route',
    'dispose',
    'source',
    'logout',
    'role',
  ]) {
    testWidgets('pending mutation $loss closes transport and ignores late401', (
      tester,
    ) async {
      final h = ResourceAdminHarness();
      await openAdmin(tester, h);
      await draft(tester);
      final session = h.account.session, closed = h.closed;
      final late = Completer<http.Response>();
      h.pendingMutation = late;
      await adminPress(tester, 'home-resource-save');
      expect(h.mutations.length, 1);
      await lose(tester, h, loss);
      expect(h.closed, greaterThan(closed));
      late.complete(
        h.json({
          'error': {'code': 'unauthorized'},
        }, 401),
      );
      h.pendingMutation = null;
      await flush(tester);
      if (!['logout', 'role'].contains(loss)) {
        expect(h.account.session, same(session));
      }
      if (loss == 'role') expect(h.account.session!.user.role.name, 'member');
      expect(adminKey('home-resource-mutation-saved'), findsNothing);
      expect(find.text('Private draft'), findsNothing);
      expect(h.mutations.length, 1);
      expect(h.haReads, 0);
      expect(tester.takeException(), isNull);
    });
  }
  for (final result in ['conflict', 'server', 'malformed']) {
    testWidgets(
      '$result clears target and requires refresh without retrying write',
      (tester) async {
        final h = ResourceAdminHarness();
        await openAdmin(tester, h);
        await draft(tester);
        if (result == 'conflict') h.mutationStatus = 409;
        if (result == 'server') h.mutationStatus = 503;
        if (result == 'malformed') h.corruptMutation = true;
        final callback = held(tester, 'home-resource-save');
        callback();
        await flush(tester);
        callback();
        await flush(tester);
        expect(h.mutations.length, 1);
        expect(adminKey('home-resource-label'), findsNothing);
        expect(
          adminKey(
            'home-resource-mutation-${result == 'conflict' ? 'conflict' : 'uncertain'}',
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<CupertinoButton>(adminKey('home-resource-admin-create'))
              .onPressed,
          isNull,
        );
        h.failList = true;
        await adminPress(tester, 'home-resource-admin-refresh');
        expect(h.mutations.length, 1);
        h.failList = false;
        await adminPress(tester, 'home-resource-admin-refresh');
        expect(h.mutations.length, 1);
        expect(
          tester
              .widget<CupertinoButton>(adminKey('home-resource-admin-create'))
              .onPressed,
          isNotNull,
        );
        expect(find.text('private-upstream'), findsNothing);
      },
    );
  }
  testWidgets(
    'same save callback and submitted key dispatch exactly one pending POST',
    (tester) async {
      final h = ResourceAdminHarness();
      await openAdmin(tester, h);
      await draft(tester);
      final callback = held(tester, 'home-resource-save'),
          submitted = tester
              .widget<CupertinoTextField>(adminKey('home-resource-order'))
              .onSubmitted!;
      final late = Completer<http.Response>();
      h.pendingMutation = late;
      callback();
      callback();
      submitted('7');
      await flush(tester);
      expect(h.mutations.length, 1);
      late.complete(h.json({'record': h.records.last}, 201));
      h.pendingMutation = null;
      await flush(tester);
      callback();
      submitted('7');
      await flush(tester);
      expect(h.mutations.length, 1);
      expect(adminKey('home-resource-mutation-saved'), findsOneWidget);
    },
  );
  testWidgets(
    'window regain cannot revive old save or numeric submit in a new form',
    (tester) async {
      final h = ResourceAdminHarness();
      await openAdmin(tester, h);
      await draft(tester);
      final callback = held(tester, 'home-resource-save'),
          submitted = tester
              .widget<CupertinoTextField>(adminKey('home-resource-order'))
              .onSubmitted!;
      await lose(tester, h, 'window');
      h.window.add(
        const WindowPolicySnapshot(
          supported: true,
          isResumed: true,
          hasWindowFocus: true,
          reason: WindowRestrictionReason.none,
        ),
      );
      await flush(tester);
      await draft(tester);
      callback();
      submitted('7');
      await flush(tester);
      expect(h.mutations, isEmpty);
      await adminPress(tester, 'home-resource-save');
      expect(h.mutations.length, 1);
    },
  );
  testWidgets('fresh password required never exposes management entry', (
    tester,
  ) async {
    final h = ResourceAdminHarness()..passwordRequired = true;
    await h.mount(tester);
    await h.signIn();
    await flush(tester);
    expect(adminKey('home-resources-manage'), findsNothing);
    expect(h.mutations, isEmpty);
  });
}
