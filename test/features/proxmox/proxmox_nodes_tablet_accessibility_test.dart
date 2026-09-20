import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/direct_home_access.dart';
import 'package:larenor/features/proxmox/data/models/proxmox_node.dart';
import 'package:larenor/features/proxmox/data/proxmox_config.dart';
import 'package:larenor/features/proxmox/presentation/proxmox_nodes_screen.dart';
import 'package:larenor/features/proxmox/providers/proxmox_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _config = ProxmoxConfig(
  host: 'pve.test',
  port: 8006,
  username: 'fixture',
  realm: 'pam',
  password: 'fixture',
  allowSelfSigned: false,
);

class _Connection extends ProxmoxConnection {
  @override
  Future<ProxmoxConfig?> build() async {
    ref.watch(directHomeAccessProvider);
    return _config;
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
  home: const ProxmoxNodesScreen(),
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets('${locale.languageCode} node hierarchy fits '
          '${width.toInt()}px at 2x text', (tester) async {
        final semantics = tester.ensureSemantics();
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var reads = 0;

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                proxmoxConnectionProvider.overrideWith(_Connection.new),
                proxmoxNodesProvider.overrideWith((_) async {
                  reads++;
                  return const [
                    ProxmoxNode(
                      name: 'pve-node',
                      status: 'online',
                      cpuFraction: .25,
                      mem: 1,
                      maxMem: 2,
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
            const ValueKey('proxmox-nodes-section-title'),
          );
          final headingNode = tester.getSemantics(heading);
          expect(headingNode.label, 'Proxmox VE');
          expect(headingNode.flagsCollection.isHeader, isTrue);
          expect(headingNode.flagsCollection.isButton, isFalse);

          for (final key in const [
            'proxmox-nodes-refresh',
            'proxmox-node-pve-node',
            'service-account-action',
          ]) {
            final action = find.byKey(ValueKey(key));
            final rect = tester.getRect(action);
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(
              tester.getSemantics(action).flagsCollection.isButton,
              isTrue,
            );
          }

          final refresh = find.descendant(
            of: find.byKey(const ValueKey('proxmox-nodes-refresh')),
            matching: find.text(l10n.commonRefresh),
          );
          Focus.of(tester.element(refresh)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await _frames(tester);
          expect(reads, 2);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
