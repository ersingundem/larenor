import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/presentation/tiles/service_tile_shell.dart';

void main() {
  testWidgets('shows a "Not connected" placeholder when not connected', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
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
}
