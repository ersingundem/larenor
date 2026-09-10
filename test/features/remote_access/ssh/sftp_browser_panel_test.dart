import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/core/window/window_policy_models.dart';
import 'package:larenor/core/window/window_policy_providers.dart';
import 'package:larenor/features/remote_access/ssh/sftp_browser_panel.dart';
import 'package:larenor/features/remote_access/ssh/sftp_file_access.dart';
import 'package:larenor/features/remote_access/ssh/sftp_models.dart';
import 'package:larenor/features/remote_access/ssh/ssh_terminal_panel.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import '../remote_profiles_test.dart' show profile;
import '../remote_profiles_ui_fixture.dart' show RemoteUi;
import 'sftp_controller_test.dart' show FakeSftpEngine, FakeSftpTransport;
import 'ssh_session_controller_test.dart' show Security, hostPin;

Finder keyed(String value) => find.byKey(ValueKey(value));

Future<void> tapKey(WidgetTester tester, String value) async {
  await tester.ensureVisible(keyed(value));
  await tester.pumpAndSettle();
  await tester.tap(keyed(value));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('saved SSH profile exposes the SFTP browser entry point', (
    tester,
  ) async {
    final ui = RemoteUi();
    await ui.mount(tester, pin: true, width: 1280);
    await ui.edit(tester);
    await ui.save(tester);
    await ui.openFirst(tester);
    expect(keyed('remote-sftp-open'), findsOneWidget);
  });

  for (final width in [600.0, 1280.0]) {
    testWidgets('$width tablet SFTP is explicit, bounded and cancellable', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final security = Security()..pin = hostPin;
      final transport = FakeSftpTransport()
        ..listing = const [
          SftpEntry.directory('Media', '/Media'),
          SftpEntry.file('notes.txt', '/notes.txt', size: 3),
        ];
      final engine = FakeSftpEngine(transport);
      final interaction = AppInteractionController();
      addTearDown(interaction.dispose);
      var active = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sshSecurityStoreProvider.overrideWithValue(security),
            sftpEngineFactoryProvider.overrideWithValue(() => engine),
            sftpFileAccessProvider.overrideWithValue(
              SftpFileAccess(
                pickFile: () async => SftpUpload('new.txt', [4, 5]),
                saveFile: (_, _) async => Uri.parse('content://saved'),
              ),
            ),
            windowPolicySnapshotProvider.overrideWith((_) async* {
              yield const WindowPolicySnapshot();
            }),
          ],
          child: CupertinoApp(
            theme: larenorTheme(brightness: Brightness.light),
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
            home: SftpBrowserPanel(
              profile: profile(),
              isCurrent: () => active,
              onBack: () => active = false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(engine.opens, 0);
      await tapKey(tester, 'sftp-connect');
      expect(engine.opens, 1);
      expect(transport.listCalls, 0);
      await tapKey(tester, 'sftp-refresh');
      expect(keyed('sftp-entry-Media'), findsOneWidget);
      expect(keyed('sftp-download-notes.txt'), findsOneWidget);
      await tapKey(tester, 'sftp-download-notes.txt');
      expect(transport.reads, ['/notes.txt']);
      await tapKey(tester, 'sftp-upload');
      expect(transport.uploaded['/new.txt'], [4, 5]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('focus loss cancels an active SFTP connection without retry', (
    tester,
  ) async {
    final security = Security()..pin = hostPin;
    final transport = FakeSftpTransport();
    final engine = FakeSftpEngine(transport);
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sshSecurityStoreProvider.overrideWithValue(security),
          sftpEngineFactoryProvider.overrideWithValue(() => engine),
          windowPolicySnapshotProvider.overrideWith((_) async* {
            yield const WindowPolicySnapshot();
          }),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppInteractionScope(
            controller: interaction,
            child: SftpBrowserPanel(
              profile: profile(),
              isCurrent: () => true,
              onBack: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'sftp-connect');
    interaction.setActive(false);
    await tester.pump();
    expect(engine.closed, isTrue);
    expect(engine.opens, 1);
  });
}
