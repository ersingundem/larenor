import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/features/remote_access/ssh/ssh_terminal_panel.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/settings/providers/settings_providers.dart';

import 'remote_profiles_ui_fixture.dart';

final class _EmptyServerSessions implements ServerSessionPersistence {
  @override
  Future<ServerSession?> read() async => null;

  @override
  Future<void> write(ServerSession? session) async {}
}

List<SemanticsNode> effectiveNodes(WidgetTester tester) {
  final nodes = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    if (!node.isMergedIntoParent) nodes.add(node);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  void visitOwner(PipelineOwner owner) {
    final root = owner.semanticsOwner?.rootSemanticsNode;
    if (root != null) visit(root);
    owner.visitChildren(visitOwner);
  }

  visitOwner(tester.binding.rootPipelineOwner);
  return nodes;
}

void main() {
  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$locale $width 2x personal boundary is readable and keyboard reachable',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            final ui = RemoteUi();
            await ui.mount(tester, width: width, scale: 2, locale: locale);
            await ui.edit(tester);
            await ui.save(tester);
            await ui.openFirst(tester);

            final l = AppLocalizations.of(
              tester.element(key('personal-session-boundary-status')),
            );
            expect(find.text(l.remoteAccessPersonalProfile), findsOneWidget);
            expect(
              find.text(l.remoteAccessPersonalSessionPolicy),
              findsOneWidget,
            );
            final boundary = effectiveNodes(tester).singleWhere(
              (node) =>
                  node.getSemanticsData().label ==
                  '${l.remoteAccessPersonalProfile}. ${l.remoteAccessPersonalSessionPolicy}',
            );
            expect(boundary.rect.height, greaterThanOrEqualTo(48));

            await tester.ensureVisible(key('remote-ssh-open'));
            await tester.pumpAndSettle();
            final title = find
                .descendant(
                  of: key('remote-ssh-open'),
                  matching: find.byType(Text),
                )
                .first;
            Focus.of(tester.element(title)).requestFocus();
            await tester.pump();
            final action = effectiveNodes(tester).singleWhere((node) {
              final data = node.getSemanticsData();
              return data.label == l.sshTitle &&
                  data.flagsCollection.isButton &&
                  data.hasAction(SemanticsAction.tap);
            });
            expect(action.rect.width, greaterThanOrEqualTo(48));
            expect(action.rect.height, greaterThanOrEqualTo(48));
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(find.text(l.sshTitle), findsWidgets);
            expect(find.byType(CupertinoTextField), findsWidgets);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  for (final loss in ['idle', 'lifecycle', 'route']) {
    testWidgets('held session launch retires after $loss', (tester) async {
      final ui = RemoteUi();
      await ui.mount(tester);
      await ui.edit(tester);
      await ui.save(tester);
      await ui.openFirst(tester);
      final old = held(tester, 'remote-ssh-open');

      if (loss == 'idle') {
        ui.interaction.setActive(false);
        await tester.pump();
        ui.interaction.setActive(true);
      } else if (loss == 'lifecycle') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      } else {
        ui.navigator.currentState!.push(
          CupertinoPageRoute<void>(
            builder: (_) =>
                const CupertinoPageScaffold(child: Text('Covered route')),
          ),
        );
        await tester.pumpAndSettle();
        ui.navigator.currentState!.pop();
      }
      await tester.pumpAndSettle();
      old();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoTextField), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('held session launch retires when the PIN authority changes', (
    tester,
  ) async {
    final ui = RemoteUi();
    await ui.mount(tester, pin: true);
    await ui.edit(tester);
    await ui.save(tester);
    await ui.openFirst(tester);
    final old = held(tester, 'remote-ssh-open');
    final container = ProviderScope.containerOf(
      tester.element(key('remote-ssh-open')),
      listen: false,
    );

    await container.read(pinLockProvider.notifier).setPin('5678');
    await tester.pumpAndSettle();
    old();
    await tester.pumpAndSettle();

    expect(find.byType(SshTerminalPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Core account authority change retires a Core-less session', (
    tester,
  ) async {
    final account = ServerAccountController(store: _EmptyServerSessions());
    addTearDown(account.dispose);
    final ui = RemoteUi();
    await ui.mount(tester, serverAccount: account);
    await ui.edit(tester);
    await ui.save(tester);
    await ui.openFirst(tester);
    await press(tester, 'remote-ssh-open');
    expect(find.byType(SshTerminalPanel), findsOneWidget);

    await account.signOut();
    await tester.pumpAndSettle();

    expect(find.byType(SshTerminalPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final protocol in ['rdp', 'vnc']) {
    testWidgets('$protocol panel does not revive after lifecycle return', (
      tester,
    ) async {
      final ui = RemoteUi();
      await ui.mount(tester);
      await ui.edit(tester);
      await press(tester, 'remote-protocol-$protocol');
      await ui.save(tester);
      await ui.openFirst(tester);
      await press(tester, 'remote-$protocol-open');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await ui.openFirst(tester);

      expect(key('remote-$protocol-open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
