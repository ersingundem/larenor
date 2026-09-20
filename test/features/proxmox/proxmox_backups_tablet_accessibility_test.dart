import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_backup.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_guest.dart';
import 'package:larenor/features/proxmox/data/proxmox_client.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_backups_screen.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import 'proxmox_transport_security_test.dart' show fixtureConfig;

class _Connection extends ProxmoxConnection {
  @override
  Future<ProxmoxConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    return fixtureConfig;
  }
}

Widget _tabletApp(Locale locale) => CupertinoApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: const ProxmoxBackupsScreen(nodeName: 'pve', storageName: 'local'),
);

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets('${locale.languageCode} backup hierarchy fits '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final client = ProxmoxClient(
          config: fixtureConfig,
          httpClient: MockClient(
            (_) async => http.Response('unexpected request', 500),
          ),
        );
        addTearDown(client.dispose);

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                proxmoxConnectionProvider.overrideWith(_Connection.new),
                proxmoxClientProvider.overrideWith((_) async => client),
                proxmoxGuestsProvider('pve').overrideWith((ref) async {
                  await ref.watch(proxmoxClientProvider.future);
                  return const [
                    ProxmoxGuest(
                      type: ProxmoxGuestType.qemu,
                      node: 'pve',
                      vmid: 100,
                      name: 'Home',
                      status: 'running',
                    ),
                  ];
                }),
                proxmoxBackupsProvider('pve', 'local').overrideWith((
                  ref,
                ) async {
                  await ref.watch(proxmoxClientProvider.future);
                  return [
                    ProxmoxBackup(
                      volumeId: 'local:backup/vzdump-qemu-100.vma.zst',
                      vmid: 100,
                      sizeBytes: 1024 * 1024 * 1024,
                      createdAt: DateTime.utc(2026, 9, 20),
                    ),
                  ];
                }),
              ],
              child: _tabletApp(locale),
            ),
          );
          await tester.pumpAndSettle();
          final l10n = await AppLocalizations.delegate.load(locale);

          expect(find.byType(AppSurface), findsOneWidget);
          expect(find.byType(SettingsSection), findsAtLeastNWidgets(2));

          final heading = find.byKey(
            const ValueKey('proxmox-backups-action-title'),
          );
          final headingNode = tester.getSemantics(heading);
          expect(headingNode.label, l10n.proxmoxBackUpNowTitle);
          expect(headingNode.flagsCollection.isHeader, isTrue);
          expect(headingNode.flagsCollection.isButton, isFalse);

          final action = find.byKey(
            const ValueKey('proxmox-backup-now-action'),
          );
          final actionRect = tester.getRect(action);
          expect(actionRect.width, greaterThanOrEqualTo(48));
          expect(actionRect.height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(action).flagsCollection.isButton, isTrue);
          expect(
            tester.getSemantics(action).flagsCollection.isEnabled,
            ui.Tristate.isTrue,
          );
          expect(
            tester.widgetList<CupertinoButton>(find.byType(CupertinoButton)),
            everyElement(
              predicate<CupertinoButton>(
                (button) => (button.minimumSize?.height ?? 0) >= 48,
              ),
            ),
          );

          final actionLabel = find.descendant(
            of: action,
            matching: find.text(l10n.proxmoxBackUpNowTitle),
          );
          Focus.of(tester.element(actionLabel)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(
            find.text('${l10n.proxmoxBackUpNowTitle} · local'),
            findsOneWidget,
          );
          expect(find.text(l10n.commonCancel), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
