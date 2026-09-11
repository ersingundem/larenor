import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote_profiles_ui_fixture.dart';

Future<void> openVnc(WidgetTester tester, RemoteUi ui) async {
  await ui.edit(tester, name: 'Studio screen');
  await press(tester, 'remote-protocol-vnc');
  await ui.save(tester);
  await ui.openFirst(tester);
  await press(tester, 'remote-vnc-open');
}

void main() {
  testWidgets('tablet panel exposes unavailable native engine honestly', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final ui = RemoteUi();
    await ui.mount(tester, width: 1280, scale: 2);
    await openVnc(tester, ui);

    expect(find.byKey(const ValueKey('vnc-session-panel')), findsOneWidget);
    expect(find.text('Clipboard: Off'), findsOneWidget);
    expect(find.text('Files: Off'), findsOneWidget);
    expect(tester.getSize(key('vnc-check')).height, greaterThanOrEqualTo(48));
    await press(tester, 'vnc-check');
    expect(
      find.textContaining('native VNC engine is not packaged'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('vnc-connect')), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('Turkish 2x panel closes when PIN or idle scope retires', (
    tester,
  ) async {
    final ui = RemoteUi();
    await ui.mount(tester, width: 600, scale: 2, locale: 'tr');
    await openVnc(tester, ui);
    expect(find.text('Pano: Kapalı'), findsOneWidget);
    ui.interaction.setActive(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vnc-session-panel')), findsNothing);
    expect(find.byKey(const ValueKey('vnc-password')), findsNothing);
  });
}
