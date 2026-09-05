import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/client_updates/presentation/client_updates_screen.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/presentation/server_vault_screen.dart';

import 'server_connection_screen_test.dart' as fixture;
import '../client_updates/client_updates_test.dart' show FakeApi;

void main() {
  for (final targetKey in ['server-vault', 'server-client-updates']) {
    for (final loss in ['idle', 'background', 'hidden', 'logout']) {
      testWidgets(
        '$targetKey disabled and captured activation retired by $loss',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final interaction = AppInteractionController();
          final visible = ValueNotifier(true);
          final updates = FakeApi();
          addTearDown(interaction.dispose);
          addTearDown(visible.dispose);
          addTearDown(updates.events.close);
          try {
            final api = fixture.Api()..requireChange = false;
            final account = ServerAccountController(
              store: fixture.Store()..value = fixture.session(),
              apiFactory: (_) => api,
            );
            await fixture.mount(
              tester,
              account,
              interaction: interaction,
              visible: visible,
              updates: updates,
            );
            final target = find.byKey(ValueKey(targetKey));
            await tester.ensureVisible(target);
            await tester.pumpAndSettle();
            final old = tester.widget<SettingsActionTile>(target).onTap!;
            switch (loss) {
              case 'idle':
                interaction.setActive(false);
              case 'background':
                await fixture.background(tester);
              case 'hidden':
                visible.value = false;
              case 'logout':
                await account.signOut();
            }
            await tester.pumpAndSettle();
            // The real account screen removes protected actions entirely when
            // this lifecycle/session boundary closes; no hidden button remains.
            expect(target, findsNothing);
            old();
            await tester.pumpAndSettle();
            switch (loss) {
              case 'idle':
                interaction.setActive(true);
              case 'background':
                await fixture.resume(tester);
              case 'hidden':
                visible.value = true;
              case 'logout':
                break;
            }
            await tester.pumpAndSettle();
            old();
            await tester.pumpAndSettle();
            expect(find.byType(ServerVaultScreen), findsNothing);
            expect(find.byType(ClientUpdatesScreen), findsNothing);
            expect(updates.downloads, 0);
            expect(updates.installs, 0);
            expect(api.changes, 0);
            expect(tester.takeException(), isNull);
          } finally {
            if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
              await fixture.resume(tester);
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            semantics.dispose();
          }
        },
      );
    }
  }

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        'member vault and updates are keyboard buttons $language $width 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            final api = fixture.Api()
              ..requireChange = false
              ..role = ServerRole.member;
            final updatesApi = FakeApi();
            addTearDown(updatesApi.events.close);
            final account = ServerAccountController(
              store: fixture.Store()
                ..value = fixture.session(role: ServerRole.member),
              apiFactory: (_) => api,
            );
            await fixture.mount(
              tester,
              account,
              language: language,
              width: width,
              scale: 2,
              updates: updatesApi,
            );
            final vault = find.byKey(const ValueKey('server-vault'));
            final vaultText = find.descendant(
              of: vault,
              matching: find.byType(Text),
            );
            await tester.ensureVisible(vault);
            await tester.pumpAndSettle();
            final node = tester.getSemantics(vaultText);
            expect(node.hasFlag(ui.SemanticsFlag.isButton), isTrue);
            expect(node.rect.height, greaterThanOrEqualTo(48));
            expect(node.label, tester.widget<Text>(vaultText).data);
            Focus.of(tester.element(vaultText)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(find.byType(ServerVaultScreen), findsOneWidget);
            Navigator.of(tester.element(find.byType(ServerVaultScreen))).pop();
            await tester.pumpAndSettle();
            await tester.ensureVisible(vault);
            Focus.of(tester.element(vaultText)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            final updates = find.byKey(const ValueKey('server-client-updates'));
            final updatesText = find.descendant(
              of: updates,
              matching: find.byType(Text),
            );
            expect(
              Focus.of(tester.element(updatesText)).hasPrimaryFocus,
              isTrue,
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.space);
            await tester.pumpAndSettle();
            expect(find.byType(ClientUpdatesScreen), findsOneWidget);
            expect(api.logouts, 0);
            expect(api.changes, 0);
            expect(updatesApi.downloads, 0);
            expect(updatesApi.installs, 0);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            semantics.dispose();
          }
        },
      );
    }
  }
}
