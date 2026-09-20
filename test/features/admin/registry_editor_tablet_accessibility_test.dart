import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/admin/data/admin_client.dart';
import 'package:larenor/features/admin/data/models/ha_area.dart';
import 'package:larenor/features/admin/data/models/ha_device.dart';
import 'package:larenor/features/admin/presentation/registry_editor_screen.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/app_page_scaffold.dart';

import 'admin_test_fakes.dart';

const _device = HaDevice(
  id: 'tablet',
  name: 'Kitchen wall display with a deliberately long accessible name',
  manufacturer: 'Larenor',
  model: 'Wall display',
  areaId: 'kitchen',
);

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  required HaAdminClient client,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        haAdminClientProvider.overrideWithValue(client),
        areasProvider.overrideWith(
          (ref) async => const [
            HaArea(areaId: 'kitchen', name: 'Kitchen and family dining area'),
          ],
        ),
      ],
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const RegistryEditorScreen.device(_device),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('captured save cannot write while editor route is covered', (
    tester,
  ) async {
    final socket = RecordingAdminSocket();
    await _mount(
      tester,
      language: 'en',
      width: 600,
      client: fakeAdminClient(socket),
    );
    await tester.enterText(find.byType(CupertinoTextField).first, 'New name');
    final save = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('registry-editor-save')),
        )
        .onPressed!;

    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          CupertinoPageRoute<void>(builder: (_) => const SizedBox.expand()),
        );
    await tester.pumpAndSettle();
    save();
    await tester.pumpAndSettle();

    expect(socket.commands, isEmpty);
  });

  testWidgets('captured save cannot write after lifecycle expiry', (
    tester,
  ) async {
    final socket = RecordingAdminSocket();
    await _mount(
      tester,
      language: 'en',
      width: 600,
      client: fakeAdminClient(socket),
    );
    await tester.enterText(find.byType(CupertinoTextField).first, 'New name');
    final save = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('registry-editor-save')),
        )
        .onPressed!;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    save();
    await tester.pump();

    expect(socket.commands, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('$language registry editor fits ${width}px at 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await _mount(
          tester,
          language: language,
          width: width,
          client: fakeAdminClient(RecordingAdminSocket()),
        );

        expect(find.byType(AppPageScaffold), findsOneWidget);
        for (final key in const [
          'registry-editor-save',
          'registry-editor-name',
          'registry-editor-area',
          'registry-editor-enabled',
        ]) {
          expect(
            tester.getRect(find.byKey(ValueKey(key))).height,
            greaterThanOrEqualTo(48),
          );
        }
        final save = find.byKey(const ValueKey('registry-editor-save'));
        expect(tester.getSemantics(save).flagsCollection.isButton, isTrue);
        final enabled = find.byKey(const ValueKey('registry-editor-enabled'));
        final l10n = AppLocalizations.of(tester.element(enabled));
        expect(tester.getSemantics(enabled).label, l10n.adminEnabled);
        expect(
          tester.getSemantics(enabled).flagsCollection.isToggled,
          ui.Tristate.isTrue,
        );
        final enabledFocus = find.byKey(
          const ValueKey('registry-editor-enabled-focus'),
        );
        Focus.of(
          tester.element(
            find.descendant(
              of: enabledFocus,
              matching: find.byType(CupertinoListTile),
            ),
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(
          tester.getSemantics(enabled).flagsCollection.isToggled,
          ui.Tristate.isFalse,
        );
        expect(
          tester.getSize(find.byType(ListView)).width,
          lessThanOrEqualTo(1000),
        );

        final name = find.byType(CupertinoTextField).first;
        await tester.tap(name);
        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.enterText(name, 'Accessible tablet name');
        await tester.pump();
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
}
