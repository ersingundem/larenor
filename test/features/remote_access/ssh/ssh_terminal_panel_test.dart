import 'dart:convert';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/ssh/ssh_security_store.dart';
import 'package:larenor/features/remote_access/ssh/ssh_engine.dart';

import '../remote_profiles_ui_fixture.dart';
import 'ssh_session_controller_test.dart' show Engine, hostPin;

Future<void> setup(
  WidgetTester t,
  RemoteUi ui,
  Engine engine, {
  double width = 1280,
  String locale = 'en',
  double scale = 1,
}) async {
  await ui.mount(
    t,
    pin: true,
    sshEngine: () => engine,
    width: width,
    locale: locale,
    scale: scale,
  );
  await ui.edit(t);
  await ui.save(t);
  await ui.openFirst(t);
  await press(t, 'remote-ssh-open');
}

Future<void> credentials(WidgetTester t) async {
  await t.enterText(key('ssh-password'), 'fixture-secret');
  await press(t, 'ssh-save-credential');
}

Future<void> connected(WidgetTester t) async {
  await credentials(t);
  await press(t, 'ssh-connect');
  expect(key('ssh-fingerprint'), findsOneWidget);
  await press(t, 'ssh-trust');
}

void main() {
  testWidgets(
    'saved personal SSH profile exposes an explicit terminal under actual PIN settings',
    (t) async {
      final ui = RemoteUi();
      final engine = Engine();
      await setup(t, ui, engine);
      expect(key('ssh-password'), findsOneWidget);
      expect(engine.opens, 0);
      expect(key('ssh-tab-1'), findsOneWidget);
      expect(key('ssh-tab-add'), findsOneWidget);
    },
  );
  testWidgets('tablet tab strip exposes status and never connects a new tab', (
    t,
  ) async {
    final ui = RemoteUi();
    final engines = <Engine>[];
    await ui.mount(
      t,
      pin: true,
      width: 1280,
      sshEngine: () {
        final engine = Engine();
        engines.add(engine);
        return engine;
      },
    );
    await ui.edit(t);
    await ui.save(t);
    await ui.openFirst(t);
    await press(t, 'remote-ssh-open');
    await credentials(t);
    await press(t, 'ssh-tab-add');
    expect(key('ssh-tab-1'), findsOneWidget);
    expect(key('ssh-tab-2'), findsOneWidget);
    expect(engines, isEmpty);
    await press(t, 'ssh-connect');
    expect(engines, hasLength(1));
    await press(t, 'ssh-trust');
    expect(find.textContaining('SSH shell open'), findsWidgets);
    await press(t, 'ssh-tab-close');
    expect(engines.single.closed, isTrue);
  });
  testWidgets(
    'actual credential store trust, output, explicit send and disconnect no replay',
    (t) async {
      final ui = RemoteUi();
      final engine = Engine();
      await setup(t, ui, engine);
      await connected(t);
      final p = (await ui.read()).profiles.single;
      expect(
        (await SshSecurityStore().readPin(
          p,
          isCurrent: () => true,
        ))!.fingerprint,
        hostPin.fingerprint,
      );
      expect(engine.channel.writes, isEmpty);
      engine.channel.out.add(utf8.encode('Merhaba Türkçe'));
      await t.pumpAndSettle();
      expect(find.text('Merhaba Türkçe'), findsOneWidget);
      await t.enterText(key('ssh-line'), 'echo merhaba');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(engine.channel.writes, isEmpty);
      await press(t, 'ssh-send');
      expect(utf8.decode(engine.channel.writes.single), 'echo merhaba\n');
      await press(t, 'ssh-disconnect');
      expect(engine.closed, isTrue);
      expect(find.text('Merhaba Türkçe'), findsNothing);
      expect(engine.opens, 1);
    },
  );
  testWidgets('MFA prompt is visible per hop and answer is never persisted', (
    t,
  ) async {
    final ui = RemoteUi();
    final engine = Engine()
      ..challenge = const SshAuthChallenge(
        name: 'Second factor',
        instruction: 'Enter current code',
        prompts: [SshAuthPrompt(text: 'One-time code', echo: false)],
      );
    await setup(t, ui, engine, width: 1280);
    await credentials(t);
    await press(t, 'ssh-connect');
    await press(t, 'ssh-trust');
    expect(find.text('Target authentication'), findsOneWidget);
    expect(find.text('Second factor'), findsOneWidget);
    await t.enterText(key('ssh-mfa-0'), '654321');
    await press(t, 'ssh-mfa-submit');
    expect(key('ssh-line'), findsOneWidget);
    expect(ui.values.values.join(), isNot(contains('654321')));
    expect(engine.channel.writes, isEmpty);
  });
  testWidgets(
    'cancel first trust stores no pin and never sends credentials as profile metadata',
    (t) async {
      final ui = RemoteUi();
      final engine = Engine();
      await setup(t, ui, engine);
      await credentials(t);
      await press(t, 'ssh-connect');
      await press(t, 'ssh-cancel');
      final p = (await ui.read()).profiles.single;
      expect(
        await SshSecurityStore().readPin(p, isCurrent: () => true),
        isNull,
      );
      expect((await ui.read()).raw, isNot(contains('fixture-secret')));
      expect(engine.closed, isTrue);
    },
  );
  testWidgets('held trust and send cannot survive actual idle retirement', (
    t,
  ) async {
    final ui = RemoteUi();
    final engine = Engine();
    await setup(t, ui, engine);
    await credentials(t);
    await press(t, 'ssh-connect');
    final trust = held(t, 'ssh-trust');
    ui.interaction.setActive(false);
    await t.pumpAndSettle();
    trust();
    await t.pumpAndSettle();
    expect(engine.closed, isTrue);
    expect(ui.values.keys.where((k) => k.startsWith('ssh_pin_')), isEmpty);
    expect(key('ssh-fingerprint'), findsNothing);
  });
  testWidgets(
    'native focus loss closes connected session before another frame',
    (t) async {
      final ui = RemoteUi();
      final engine = Engine();
      await setup(t, ui, engine);
      await connected(t);
      final send = held(t, 'ssh-send');
      final e = ViewFocusEvent(
        viewId: t.view.viewId,
        state: ViewFocusState.unfocused,
        direction: ViewFocusDirection.undefined,
      );
      t.binding.handleViewFocusChanged(e);
      expect(engine.closed, isTrue);
      send();
      await t.pumpAndSettle();
      expect(engine.channel.writes, isEmpty);
      expect(key('ssh-output'), findsNothing);
    },
  );
  testWidgets('forget credential cancel and confirm preserve pinned host', (
    t,
  ) async {
    final ui = RemoteUi();
    final engine = Engine();
    await setup(t, ui, engine);
    await connected(t);
    await press(t, 'ssh-disconnect');
    await press(t, 'ssh-forget');
    await press(t, 'ssh-forget-cancel');
    expect(key('ssh-connect'), findsOneWidget);
    await press(t, 'ssh-forget');
    await press(t, 'ssh-forget-confirm');
    final p = (await ui.read()).profiles.single;
    expect(
      await SshSecurityStore().readCredential(p, isCurrent: () => true),
      isNull,
    );
    expect(
      await SshSecurityStore().readPin(p, isCurrent: () => true),
      isNotNull,
    );
  });
  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets(
        '$locale $width tablet 2x credential and trust keyboard targets',
        (t) async {
          final semantics = t.ensureSemantics();
          try {
            final ui = RemoteUi();
            final engine = Engine();
            await setup(t, ui, engine, width: width, locale: locale, scale: 2);
            await credentials(t);
            await press(t, 'ssh-connect');
            await t.ensureVisible(key('ssh-trust'));
            await t.pumpAndSettle();
            final button = find.descendant(
              of: key('ssh-trust'),
              matching: find.byType(CupertinoButton),
            );
            expect(t.getSize(button).height, greaterThanOrEqualTo(48));
            expect(t.getSize(button).width, greaterThanOrEqualTo(48));
            var focused = false;
            for (var i = 0; i < 30; i++) {
              await t.sendKeyEvent(LogicalKeyboardKey.tab);
              await t.pumpAndSettle();
              final ctx = FocusManager.instance.primaryFocus?.context;
              if (ctx != null &&
                  (ctx == t.element(button) ||
                      _under(ctx, t.element(button)))) {
                focused = true;
                break;
              }
            }
            expect(focused, isTrue);
            await t.sendKeyEvent(LogicalKeyboardKey.enter);
            await t.pumpAndSettle();
            expect(key('ssh-line'), findsOneWidget);
            expect(engine.channel.writes, isEmpty);
            expect(t.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}

bool _under(BuildContext child, Element root) {
  var found = false;
  child.visitAncestorElements((e) {
    if (e == root) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}
