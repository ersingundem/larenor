import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote_profiles_ui_fixture.dart';

Future<void> openRdp(WidgetTester tester, RemoteUi ui) async {
  await ui.edit(tester, name: 'Office PC');
  await press(tester, 'remote-protocol-rdp');
  await ui.save(tester);
  await ui.openFirst(tester);
  await press(tester, 'remote-rdp-open');
}

void main() {
  testWidgets('tablet panel exposes unavailable native engine honestly', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final ui = RemoteUi();
    await ui.mount(tester, width: 1280, scale: 2);
    await openRdp(tester, ui);

    expect(find.byKey(const ValueKey('rdp-session-panel')), findsOneWidget);
    expect(find.text('Clipboard: Off'), findsOneWidget);
    expect(find.text('Audio: Off'), findsOneWidget);
    expect(find.text('Files: Off'), findsOneWidget);
    await press(tester, 'rdp-check');
    expect(
      find.textContaining('native RDP engine is not packaged'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('rdp-connect')), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('Turkish 2x panel closes when PIN or idle scope retires', (
    tester,
  ) async {
    final ui = RemoteUi();
    await ui.mount(tester, width: 600, scale: 2, locale: 'tr');
    await openRdp(tester, ui);
    expect(find.text('Pano: Kapalı'), findsOneWidget);
    ui.interaction.setActive(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rdp-session-panel')), findsNothing);
    expect(find.byKey(const ValueKey('rdp-password')), findsNothing);
  });

  testWidgets('personal gateway display keyboard and clipboard settings persist', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final ui = RemoteUi();
    await ui.mount(tester, width: 1280, scale: 2);
    await openRdp(tester, ui);

    await tester.enterText(key('rdp-settings-domain'), 'LARENOR');
    await tester.enterText(key('rdp-settings-gateway-host'), 'gateway.home.arpa');
    await tester.enterText(key('rdp-settings-gateway-port'), '443');
    await tester.enterText(key('rdp-settings-gateway-user'), 'gateway-user');
    await press(tester, 'rdp-keyboard-turkishQ');
    await press(tester, 'rdp-clipboard-clientToRemote');
    await press(tester, 'rdp-settings-save');
    expect(find.text('RDP settings saved.'), findsOneWidget);

    expect(tester.getSize(key('rdp-settings-save')).height, greaterThanOrEqualTo(48));
    await press(tester, 'rdp-back');
    await press(tester, 'remote-rdp-open');
    expect(
      tester.widget<CupertinoTextField>(key('rdp-settings-domain')).controller!.text,
      'LARENOR',
    );
    expect(
      tester.widget<CupertinoTextField>(key('rdp-settings-gateway-host')).controller!.text,
      'gateway.home.arpa',
    );
    expect(find.textContaining('Turkish Q'), findsOneWidget);
    expect(find.textContaining('Device to remote'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
