import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/features/remote_access/data/remote_profiles.dart';

import 'remote_profiles_ui_fixture.dart';

void main() {
  testWidgets(
    'personal remote targets are visible in tablet Settings without Core or Proxmox',
    (t) async {
      final h = RemoteUi();
      await h.mount(t, width: 1280);
      expect(find.text('No saved remote targets'), findsOneWidget);
      expect(
        h.calls.where(
          (c) => c.contains('server_session') || c.contains('proxmox'),
        ),
        isEmpty,
      );
    },
  );
  testWidgets(
    'actual PIN create protocol edit copy delete cancel/confirm and reopen',
    (t) async {
      final h = RemoteUi();
      h.values['unrelated'] = 'keep';
      await h.mount(t, pin: true);
      await h.edit(t, host: '[2001:db8::1]');
      await press(t, 'remote-protocol-rdp');
      expect(
        t.widget<CupertinoTextField>(key('remote-port')).controller!.text,
        '3389',
      );
      await h.save(t);
      expect(h.writes, 1);
      await h.openFirst(t);
      expect(find.textContaining('secure RDP readiness panel'), findsOneWidget);
      expect(find.text('Saved connection'), findsOneWidget);
      expect(find.text('Not yet verified'), findsOneWidget);
      expect(find.text('Data read successfully'), findsNothing);
      await press(t, 'remote-copy');
      expect(h.clipboard, '[2001:db8::1]:3389');
      await press(t, 'remote-edit');
      await t.enterText(key('remote-host'), 'HOST.Example.');
      await h.save(t);
      expect((await h.read()).profiles.single.host, 'host.example');
      await h.openFirst(t);
      await press(t, 'remote-delete');
      final old = held(t, 'remote-delete-confirm');
      await press(t, 'remote-delete-cancel');
      old();
      await t.pumpAndSettle();
      expect(h.writes, 2);
      await press(t, 'remote-delete');
      await press(t, 'remote-delete-confirm');
      expect((await h.read()).profiles, isEmpty);
      expect(h.values['unrelated'], 'keep');
      expect(h.writes, 3);
    },
  );
  testWidgets(
    'uncertain platform write shows explicit reload without automatic replay',
    (t) async {
      final h = RemoteUi();
      await h.mount(t);
      await h.edit(t);
      h.failWrite = true;
      await h.save(t);
      expect(
        find.textContaining('save could not be confirmed'),
        findsOneWidget,
      );
      expect(h.writes, 1);
      h.failWrite = false;
      await press(t, 'remote-refresh');
      expect(find.text('NAS'), findsOneWidget);
      expect(h.writes, 1);
    },
  );
  testWidgets('invalid host and port stay editable and perform no writes', (
    t,
  ) async {
    final h = RemoteUi();
    await h.mount(t);
    await h.edit(t, host: 'ssh://host');
    await h.save(t);
    expect(find.textContaining('valid IPv4'), findsOneWidget);
    expect(h.writes, 0);
    await t.enterText(key('remote-host'), 'localhost');
    await t.enterText(key('remote-port'), '0');
    await h.save(t);
    expect(find.textContaining('1 to 65535'), findsOneWidget);
    expect(h.writes, 0);
  });
  for (final loss in ['idle', 'background', 'window', 'native', 'covered']) {
    testWidgets('held save cannot write after $loss and return', (t) async {
      final h = RemoteUi();
      await h.mount(t, pin: true);
      await h.edit(t);
      final old = held(t, 'remote-save');
      if (loss == 'idle') {
        h.interaction.setActive(false);
        await t.pump();
        h.interaction.setActive(true);
      }
      if (loss == 'background') {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          t.binding.handleAppLifecycleStateChanged(state);
        }
        await t.pump();
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          t.binding.handleAppLifecycleStateChanged(state);
        }
      }
      if (loss == 'window') {
        h.windows.add(
          const WindowPolicySnapshot(
            supported: true,
            isResumed: true,
            hasWindowFocus: false,
          ),
        );
        await t.pump();
        h.windows.add(const WindowPolicySnapshot());
      }
      if (loss == 'native') {
        t.binding.handleViewFocusChanged(
          ViewFocusEvent(
            viewId: t.view.viewId,
            state: ViewFocusState.unfocused,
            direction: ViewFocusDirection.undefined,
          ),
        );
        await t.pump();
        t.binding.handleViewFocusChanged(
          ViewFocusEvent(
            viewId: t.view.viewId,
            state: ViewFocusState.focused,
            direction: ViewFocusDirection.undefined,
          ),
        );
      }
      if (loss == 'covered') {
        h.navigator.currentState!.push(
          CupertinoPageRoute<void>(
            builder: (_) =>
                const CupertinoPageScaffold(child: Text('Other page')),
          ),
        );
        await t.pumpAndSettle();
        h.navigator.currentState!.pop();
      }
      await t.pumpAndSettle();
      old();
      await t.pumpAndSettle();
      expect(h.writes, 0);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('PIN loss during secure read stops write and clears draft', (
    t,
  ) async {
    final h = RemoteUi();
    await h.mount(t);
    await h.edit(t);
    h.afterRead = (key) async {
      if (key == RemoteProfilesStore.storageKey) h.interaction.setActive(false);
    };
    await h.save(t);
    expect(h.writes, 0);
    expect(find.text('NAS'), findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets('refresh retires held row from a deleted profile', (t) async {
    final h = RemoteUi();
    await h.mount(t);
    await h.edit(t);
    await h.save(t);
    final snapshot = await h.read();
    final old = held(t, 'remote-profile-${snapshot.profiles.single.id}');
    await RemoteProfilesStore().replace(snapshot, [], isCurrent: () => true);
    await press(t, 'remote-refresh');
    old();
    await t.pumpAndSettle();
    expect(key('remote-edit'), findsNothing);
    expect(find.text('No saved remote targets'), findsOneWidget);
  });
  testWidgets('failed refresh retires a previously held row', (t) async {
    final h = RemoteUi();
    await h.mount(t);
    await h.edit(t);
    await h.save(t);
    final snapshot = await h.read();
    final old = held(t, 'remote-profile-${snapshot.profiles.single.id}');
    h.values[RemoteProfilesStore.storageKey] = 'corrupt';
    await press(t, 'remote-refresh');
    old();
    await t.pumpAndSettle();
    expect(key('remote-edit'), findsNothing);
    expect(find.text('NAS'), findsNothing);
    expect(key('remote-error'), findsOneWidget);
  });
}
