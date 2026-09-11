import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/presentation/tiles/service_tile_shell.dart';
import 'package:larenor/features/health/data/connection_evidence.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

void main() {
  testWidgets('shows a "Not connected" placeholder when not connected', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ServiceTileShell(
          icon: CupertinoIcons.play_rectangle,
          title: 'Jellyfin',
          connected: false,
          onTap: () {},
          lines: const ['Should not show'],
        ),
      ),
    );

    expect(find.text('Jellyfin'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Should not show'), findsNothing);
  });

  testWidgets('shows the provided lines when connected', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ServiceTileShell(
          icon: CupertinoIcons.square_stack_3d_up,
          title: 'Proxmox',
          connected: true,
          onTap: () {},
          lines: const ['pve1 · CPU 25% · RAM 40%'],
        ),
      ),
    );

    expect(find.text('Proxmox'), findsOneWidget);
    expect(find.text('Not connected'), findsNothing);
    expect(find.text('pve1 · CPU 25% · RAM 40%'), findsOneWidget);
  });

  testWidgets('calls onTap when tapped', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ServiceTileShell(
          icon: CupertinoIcons.wifi,
          title: 'Keenetic',
          connected: true,
          onTap: () => tapped = true,
          lines: const ['3 devices online'],
        ),
      ),
    );

    await tester.tap(find.text('Keenetic'));
    expect(tapped, isTrue);
  });

  testWidgets('saved profile does not make a service dashboard card verified', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ServiceTileShell(
          icon: CupertinoIcons.play_rectangle,
          title: 'Jellyfin',
          connected: true,
          evidence: const ConnectionEvidence.saved(),
          onTap: () {},
          lines: const ['Continue watching'],
        ),
      ),
    );

    expect(find.text('Saved connection'), findsOneWidget);
    expect(find.text('Not yet verified'), findsOneWidget);
    expect(find.text('Data read successfully'), findsNothing);
    expect(find.text('Continue watching'), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(ServiceTileShell)).label,
      contains('Saved connection'),
    );
  });
}
