import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/proxmox/core_power/proxmox_power_controller.dart';
import 'package:larenor/features/proxmox/core_power/proxmox_power_panel.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'proxmox_power_authority_test.dart' show FakeGateway, target;

Widget app(
  Widget child, {
  Locale locale = const Locale('en'),
  double scale = 1,
}) {
  return CupertinoApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
    ],
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: CupertinoPageScaffold(child: child),
    ),
  );
}

void main() {
  testWidgets('member has no controls and cannot cause a request', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = ProxmoxPowerController(
      gateway: gateway,
      target: target,
      current: () => true,
    );
    await tester.pumpWidget(
      app(
        ProxmoxPowerPanel(
          controller: controller,
          isAdmin: false,
          canWrite: true,
        ),
      ),
    );
    expect(find.text('Power controls'), findsNothing);
    expect(gateway.previews, 0);
    await tester.pumpWidget(
      app(
        ProxmoxPowerPanel(
          controller: controller,
          isAdmin: true,
          canWrite: false,
        ),
      ),
    );
    final shutdown = tester.widget<CupertinoButton>(
      find.widgetWithText(CupertinoButton, 'Shut down'),
    );
    expect(shutdown.onPressed, isNull);
    expect(gateway.previews, 0);
    controller.dispose();
  });

  for (final size in [const Size(600, 900), const Size(1280, 900)]) {
    testWidgets('${size.width.toInt()}px 2x tablet remains usable', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = ProxmoxPowerController(
        gateway: FakeGateway(),
        target: target,
        current: () => true,
      );
      await tester.pumpWidget(
        app(
          ProxmoxPowerPanel(
            controller: controller,
            isAdmin: true,
            canWrite: true,
          ),
          scale: 2,
        ),
      );
      expect(tester.takeException(), isNull);
      for (final button in tester.widgetList<CupertinoButton>(
        find.byType(CupertinoButton),
      )) {
        expect(button.minimumSize?.height ?? 0, greaterThanOrEqualTo(48));
      }
      controller.dispose();
    });
  }

  testWidgets('keyboard preview never auto-confirms high-risk action', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = ProxmoxPowerController(
      gateway: gateway,
      target: target,
      current: () => true,
    );
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      app(
        ProxmoxPowerPanel(
          controller: controller,
          isAdmin: true,
          canWrite: true,
        ),
      ),
    );
    for (var index = 0; index < 3; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(gateway.previews, 1);
    expect(gateway.confirms, 0);
    expect(find.bySemanticsLabel('Give second confirmation'), findsOneWidget);
    expect(
      tester
          .widget<CupertinoButton>(
            find.widgetWithText(CupertinoButton, 'Explicitly confirm'),
          )
          .onPressed,
      isNull,
    );
    semantics.dispose();
    controller.dispose();
  });

  testWidgets('backgrounding invalidates review and late confirm', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final controller = ProxmoxPowerController(
      gateway: gateway,
      target: target,
      current: () => true,
    );
    await tester.pumpWidget(
      app(
        ProxmoxPowerPanel(
          controller: controller,
          isAdmin: true,
          canWrite: true,
        ),
      ),
    );
    await tester.tap(find.text('Reboot'));
    await tester.pump();
    expect(controller.phase, ProxmoxPowerPhase.ready);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(controller.phase, ProxmoxPowerPhase.idle);
    expect(gateway.confirms, 0);
    controller.dispose();
  });

  testWidgets('Turkish panel exposes 48dp TalkBack actions', (tester) async {
    final controller = ProxmoxPowerController(
      gateway: FakeGateway(),
      target: target,
      current: () => true,
    );
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      app(
        ProxmoxPowerPanel(
          controller: controller,
          isAdmin: true,
          canWrite: true,
        ),
        locale: const Locale('tr'),
        scale: 2,
      ),
    );
    final reboot = find.widgetWithText(CupertinoButton, 'Yeniden başlat');
    expect(tester.getSize(reboot).height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Yeniden başlat'), findsWidgets);
    semantics.dispose();
    controller.dispose();
  });

  testWidgets('production entry fails closed without exact target revisions', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      app(
        ProxmoxPowerEntry(
          isAdmin: true,
          canWrite: true,
          target: null,
          current: () => true,
          onOpen: (_) => opened++,
        ),
      ),
    );
    final entry = tester.widget<CupertinoButton>(
      find.byKey(const ValueKey('core-proxmox-power-open')),
    );
    expect(entry.onPressed, isNull);
    expect(opened, 0);
    expect(find.text('Exact guest status is required.'), findsOneWidget);
  });

  testWidgets('production entry rechecks route/PIN authority before opening', (
    tester,
  ) async {
    var current = false, opened = 0;
    await tester.pumpWidget(
      app(
        ProxmoxPowerEntry(
          isAdmin: true,
          canWrite: true,
          target: target,
          current: () => current,
          onOpen: (_) => opened++,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('core-proxmox-power-open')));
    expect(opened, 0);
    current = true;
    await tester.tap(find.byKey(const ValueKey('core-proxmox-power-open')));
    expect(opened, 1);
  });
}
