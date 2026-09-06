import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/home_people/presentation/home_people_screen.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/core/home_source_store.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/features/settings/data/pin_lock_store.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';

import '../../core/home_scope_fixture.dart' show flush;
import 'home_people_ui_fixture.dart';
import 'home_people_ui_test.dart' show key, press, openPeople, openManagement;

VoidCallback held(WidgetTester tester, String value) => tester
    .widget<CupertinoButton>(
      find.descendant(of: key(value), matching: find.byType(CupertinoButton)),
    )
    .onPressed!;
Future<void> draft(WidgetTester tester) async {
  await press(tester, 'home-people-create');
  await tester.enterText(key('home-people-label'), 'Private draft');
  await tester.enterText(key('home-people-order'), '7');
}

class BadPinRead extends PinLockStore {
  bool fail = false;
  @override
  Future<String?> read() async {
    if (fail) throw StateError('private-pin-failure');
    return super.read();
  }
}

void main() {
  for (final loss in ['focus', 'pip', 'paused', 'loading']) {
    testWidgets(
      'entry held callback cannot open route when window policy is $loss',
      (tester) async {
        final h = PeopleUiHarness();
        await h.mount(tester);
        await h.signIn();
        await flush(tester);
        final callback = held(tester, 'home-people-entry');
        if (loss == 'loading') {
          h.runtime(tester).invalidate(windowPolicySnapshotProvider);
          expect(
            h.runtime(tester).read(windowPolicySnapshotProvider).isLoading,
            isTrue,
          );
        } else {
          h.window.add(
            WindowPolicySnapshot(
              supported: true,
              isResumed: loss != 'paused',
              hasWindowFocus: loss != 'focus',
              isPictureInPicture: loss == 'pip',
              reason: WindowRestrictionReason.noFocus,
            ),
          );
          await flush(tester);
        }
        callback();
        await flush(tester);
        expect(find.byType(HomePeopleScreen), findsNothing);
        expect(h.peopleReads, 0);
        expect(h.haReads, 0);
      },
    );
  }
  testWidgets(
    'entry error is closed and old callback stays retired after fresh policy',
    (tester) async {
      final h = PeopleUiHarness();
      await h.mount(tester);
      await h.signIn();
      await flush(tester);
      final old = held(tester, 'home-people-entry');
      h.window.addError(StateError('private-policy'));
      await flush(tester);
      old();
      await flush(tester);
      expect(find.byType(HomePeopleScreen), findsNothing);
      expect(h.peopleReads, 0);
      expect(find.text('private-policy'), findsNothing);
      h.runtime(tester).invalidate(windowPolicySnapshotProvider);
      await flush(tester);
      old();
      await flush(tester);
      expect(find.byType(HomePeopleScreen), findsNothing);
      await press(tester, 'home-people-entry');
      expect(h.peopleReads, 1);
    },
  );
  testWidgets('covered fallback back cannot pop the covering route', (
    tester,
  ) async {
    final h = PeopleUiHarness();
    await openPeople(tester, h);
    final nav = Navigator.of(tester.element(key('home-people-list')));
    unawaited(
      nav.push(
        CupertinoPageRoute<void>(
          builder: (_) => const CupertinoPageScaffold(child: Text('Covered')),
        ),
      ),
    );
    await flush(tester);
    final back = find.byKey(
      const ValueKey('home-people-back'),
      skipOffstage: false,
    );
    final button = tester.widget<CupertinoButton>(
      find.descendant(
        of: back,
        matching: find.byType(CupertinoButton, skipOffstage: false),
        skipOffstage: false,
      ),
    );
    button.onPressed?.call();
    await flush(tester);
    expect(find.text('Covered'), findsOneWidget);
    expect(h.peopleReads, 1);
  });
  testWidgets(
    'actual PeopleButton refresh supports Enter and Space without duplicate activation',
    (tester) async {
      final h = PeopleUiHarness();
      await openPeople(tester, h);
      final button = find.descendant(
        of: key('home-people-refresh'),
        matching: find.byType(Text),
      );
      Focus.of(tester.element(button)).requestFocus();
      await flush(tester);
      final before = h.peopleReads;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await flush(tester);
      expect(h.peopleReads, before + 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await flush(tester);
      expect(h.peopleReads, before + 2);
    },
  );
  for (final pending in [false, true]) {
    for (final loss in [
      'window',
      'native',
      'background',
      'source',
      'logout',
      'role',
      'pin-loading',
      'pin-rotation',
      'root-route',
    ]) {
      testWidgets(
        '$loss retires actual admin ${pending ? 'late401' : 'held save'} and private draft',
        (tester) async {
          final h = PeopleUiHarness();
          await openManagement(tester, h, pin: '1234');
          await draft(tester);
          final callback = held(tester, 'home-people-save'),
              late = Completer<http.Response>();
          if (pending) {
            h.pendingWrite = late;
            await press(tester, 'home-people-save');
          }
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
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
            case 'source':
              h.source.writeFails = true;
              await h.home(tester).choose(HomeSource.directLocal);
            case 'logout':
              await h.account.signOut();
            case 'role':
              h.role = 'member';
              h.now = h.account.session!.expiresAt;
              await h.account.ensureSession();
            case 'pin-loading':
              h.runtime(tester).invalidate(pinLockProvider);
              expect(h.runtime(tester).read(pinLockProvider).isLoading, isTrue);
            case 'pin-rotation':
              await h
                  .runtime(tester)
                  .read(pinLockProvider.notifier)
                  .setPin('5678');
            case 'root-route':
              unawaited(
                Navigator.of(
                  tester.element(key('home-people-admin')),
                  rootNavigator: true,
                ).push(
                  CupertinoPageRoute<void>(
                    builder: (_) =>
                        const CupertinoPageScaffold(child: Text('Covered')),
                  ),
                ),
              );
          }
          if (pending) {
            late.complete(
              h.json({
                'error': {'code': 'unauthorized'},
              }, 401),
            );
            h.pendingWrite = null;
          } else {
            callback();
          }
          await flush(tester);
          expect(h.writes.length, pending ? 1 : 0);
          expect(find.text('Private draft'), findsNothing);
          expect(h.account.session == null, loss == 'logout');
          expect(h.haReads, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'PIN storage failure preframe retires form without raw error and fresh gate can recover',
    (tester) async {
      final pin = BadPinRead(), h = PeopleUiHarness(pinStore: pin);
      await openManagement(tester, h);
      await draft(tester);
      final callback = held(tester, 'home-people-save'),
          container = h.runtime(tester);
      pin.fail = true;
      container.invalidate(pinLockProvider);
      try {
        await container.read(pinLockProvider.future);
      } catch (_) {}
      callback();
      await flush(tester);
      expect(h.writes, isEmpty);
      expect(find.text('private-pin-failure'), findsNothing);
      expect(find.text('Private draft'), findsNothing);
      pin.fail = false;
      container.invalidate(pinLockProvider);
      await container.read(pinLockProvider.future);
      await flush(tester);
      await draft(tester);
      callback();
      expect(h.writes, isEmpty);
      await press(tester, 'home-people-save');
      expect(h.writes.length, 1);
    },
  );
  testWidgets(
    'member route cover hides rows and pop obtains a new read owner',
    (tester) async {
      final h = PeopleUiHarness()..role = 'member';
      await openPeople(tester, h);
      final refresh = held(tester, 'home-people-refresh'),
          nav = Navigator.of(tester.element(key('home-people-list'))),
          before = h.peopleReads;
      unawaited(
        nav.push(
          CupertinoPageRoute<void>(
            builder: (_) => const CupertinoPageScaffold(child: Text('Covered')),
          ),
        ),
      );
      await flush(tester);
      refresh();
      expect(h.peopleReads, before);
      nav.pop();
      await flush(tester);
      expect(h.peopleReads, before + 1);
      refresh();
      await flush(tester);
      expect(h.peopleReads, before + 1);
      expect(find.text('Deniz Öztürk'), findsOneWidget);
    },
  );
  testWidgets(
    'old delete and ACL confirmation callbacks cannot be reused after cancel',
    (tester) async {
      final h = PeopleUiHarness();
      await openManagement(tester, h);
      await press(tester, 'home-people-delete-${'1' * 32}');
      final oldDelete = held(tester, 'home-people-confirm-delete');
      await press(tester, 'home-people-cancel-edit');
      await press(tester, 'home-people-delete-${'1' * 32}');
      oldDelete();
      await flush(tester);
      expect(h.writes, isEmpty);
      await press(tester, 'home-people-cancel-edit');
      await press(tester, 'home-people-grants-${'1' * 32}');
      await press(tester, 'home-people-user-${h.peopleContract['subjectId']}');
      await press(tester, 'home-people-permission-none');
      final oldSave = held(tester, 'home-people-grant-save');
      oldSave();
      await flush(tester);
      final confirm = held(tester, 'home-people-confirm-revoke');
      oldSave();
      await flush(tester);
      expect(h.writes, isEmpty);
      await press(tester, 'home-people-grant-cancel');
      confirm();
      await flush(tester);
      expect(h.writes, isEmpty);
    },
  );
  for (final phase in ['users', 'acl', 'put']) {
    testWidgets(
      'ACL $phase late401 after PIN retirement preserves current account',
      (tester) async {
        final h = PeopleUiHarness(), late = Completer<http.Response>();
        await openManagement(tester, h, pin: '1234');
        if (phase == 'users') h.pendingUsers = late;
        if (phase == 'acl') h.pendingGrants = late;
        await press(tester, 'home-people-grants-${'1' * 32}');
        if (phase == 'put') {
          await press(
            tester,
            'home-people-user-${h.peopleContract['subjectId']}',
          );
          await press(tester, 'home-people-permission-readWrite');
          h.pendingWrite = late;
          await press(tester, 'home-people-grant-save');
        }
        final container = h.runtime(tester);
        container.invalidate(pinLockProvider);
        expect(container.read(pinLockProvider).isLoading, isTrue);
        late.complete(
          h.json({
            'error': {'code': 'unauthorized'},
          }, 401),
        );
        h.pendingUsers = null;
        h.pendingGrants = null;
        h.pendingWrite = null;
        await flush(tester);
        expect(h.account.session, isNotNull);
        expect(h.writes.length, phase == 'put' ? 1 : 0);
        expect(find.text('Member'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
