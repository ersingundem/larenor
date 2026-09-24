import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/inventory/data/inventory_scanner.dart';
import 'package:larenor/features/web_panel/presentation/web_panel_qr_scanner.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final class _Session implements InventoryScannerSession {
  final valuesController = StreamController<String>.broadcast();
  final errorsController = StreamController<InventoryCameraFailure>.broadcast();
  bool closed = false;
  @override
  Stream<String> get values => valuesController.stream;
  @override
  Stream<InventoryCameraFailure> get errors => errorsController.stream;
  @override
  Widget preview() => const ColoredBox(
    key: ValueKey('web-panel-qr-camera-preview'),
    color: CupertinoColors.black,
  );
  @override
  Future<void> close() async {
    closed = true;
    await valuesController.close();
    await errorsController.close();
  }
}

final class _Platform implements InventoryScannerPlatform {
  final session = _Session();
  @override
  InventoryScannerSession create() => session;
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final size in const [Size(600, 900), Size(1280, 900)]) {
      testWidgets('visible QR permission surface ${locale.languageCode} $size at 2x', (tester) async {
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final platform = _Platform();
        String? accepted;
        await tester.pumpWidget(
          CupertinoApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WebPanelQrScanner(
              platform: platform,
              isCurrent: () => true,
              onAccepted: (value) => accepted = value,
              onCancel: () {},
            ),
          ),
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('web-panel-qr-visible-permission')), findsOneWidget);
        expect(find.byKey(const ValueKey('web-panel-qr-camera-preview')), findsOneWidget);
        expect(tester.takeException(), isNull);
        platform.session.valuesController.add('https://fixture.invalid/item/42');
        await tester.pumpAndSettle();
        expect(accepted, 'https://fixture.invalid/item/42');
        expect(platform.session.closed, isTrue);
      });
    }
  }

  testWidgets('background and stale authority close camera without publishing', (tester) async {
    final platform = _Platform();
    var current = true;
    var accepted = false;
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WebPanelQrScanner(
          platform: platform,
          isCurrent: () => current,
          onAccepted: (_) => accepted = true,
          onCancel: () {},
        ),
      ),
    );
    await tester.pump();
    current = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    platform.session.valuesController.add('stale-private-value');
    await tester.pump();
    expect(accepted, isFalse);
    expect(platform.session.closed, isTrue);
  });
}
