import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/remote_access/ssh/ssh_terminal_panel.dart';
import 'package:larenor/features/remote_access/ssh/ssh_tunnel_panel.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../remote_profiles_test.dart' show profile;
import 'ssh_tunnel_controller_test.dart' show TunnelEngine, TunnelSecurity;
import 'ssh_session_controller_test.dart' show hostPin;

Finder keyed(String value) => find.byKey(ValueKey(value));
Future<void> tapKey(WidgetTester tester, String value) async {
  await tester.ensureVisible(keyed(value));
  await tester.pumpAndSettle();
  await tester.tap(keyed(value));
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [600.0, 1280.0]) {
    testWidgets('$width tablet saves then explicitly starts loopback tunnel', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final security = TunnelSecurity()..pin = hostPin;
      final engine = TunnelEngine();
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sshSecurityStoreProvider.overrideWithValue(security),
            sshTunnelEngineFactoryProvider.overrideWithValue(() => engine),
            windowPolicySnapshotProvider.overrideWith((_) async* {
              yield const WindowPolicySnapshot();
            }),
          ],
          child: CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: AppInteractionScope(
                controller: interaction,
                child: child!,
              ),
            ),
            home: SshTunnelPanel(
              profile: profile(),
              isCurrent: () => true,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.starts, 0);
      await tester.enterText(keyed('tunnel-name'), 'Media');
      await tester.enterText(keyed('tunnel-local-port'), '8088');
      await tester.enterText(keyed('tunnel-target-host'), '127.0.0.1');
      await tester.enterText(keyed('tunnel-target-port'), '8096');
      await tapKey(tester, 'tunnel-save');
      expect(engine.starts, 0);
      await tapKey(tester, 'tunnel-start');
      expect(engine.starts, 1);
      expect(find.text('127.0.0.1:8088'), findsOneWidget);
      await tapKey(tester, 'tunnel-stop');
      expect(engine.closed, isTrue);
      expect(engine.starts, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
