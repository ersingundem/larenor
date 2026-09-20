import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/admin/data/admin_client.dart';
import 'package:larenor/features/admin/data/models/ha_area.dart';
import 'package:larenor/features/admin/data/models/ha_device.dart';
import 'package:larenor/features/admin/presentation/devices_screen.dart';
import 'package:larenor/features/admin/presentation/registry_editor_screen.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

import 'admin_test_fakes.dart';

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  HaAdminClient? client,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        haAdminClientProvider.overrideWithValue(
          client ?? fakeAdminClient(RecordingAdminSocket()),
        ),
        devicesProvider.overrideWith(
          (ref) async => const [
            HaDevice(
              id: 'tablet',
              name: 'Kitchen tablet',
              manufacturer: 'Larenor',
              model: 'Wall display',
              areaId: 'kitchen',
            ),
          ],
        ),
        areasProvider.overrideWith(
          (ref) async => const [HaArea(areaId: 'kitchen', name: 'Kitchen')],
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
        home: const DevicesScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('captured device action cannot cross HA admin authority', (
    tester,
  ) async {
    final oldSocket = RecordingAdminSocket();
    final replacementSocket = RecordingAdminSocket();
    await _mount(
      tester,
      language: 'en',
      width: 600,
      client: fakeAdminClient(oldSocket),
    );
    final open = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('admin-device-tablet')),
        )
        .onPressed!;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DevicesScreen)),
    );
    container.updateOverrides([
      haAdminClientProvider.overrideWithValue(
        fakeAdminClient(replacementSocket),
      ),
      devicesProvider.overrideWith(
        (ref) async => const [
          HaDevice(
            id: 'tablet',
            name: 'Kitchen tablet',
            manufacturer: 'Larenor',
            model: 'Wall display',
            areaId: 'kitchen',
          ),
        ],
      ),
      areasProvider.overrideWith(
        (ref) async => const [HaArea(areaId: 'kitchen', name: 'Kitchen')],
      ),
    ]);
    await tester.pumpAndSettle();

    open();
    await tester.pumpAndSettle();

    expect(find.byType(RegistryEditorScreen), findsNothing);
  });

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('$language device action is accessible at ${width}px 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await _mount(tester, language: language, width: width);

        expect(find.byType(ServiceRootScaffold), findsOneWidget);
        expect(find.byType(SettingsSection), findsOneWidget);
        expect(find.byType(SettingsActionTile), findsOneWidget);
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('devices-list-header')))
              .flagsCollection
              .isHeader,
          isTrue,
        );

        final device = find.byKey(const ValueKey('admin-device-tablet'));
        expect(tester.getRect(device).height, greaterThanOrEqualTo(48));
        expect(tester.getSemantics(device).flagsCollection.isButton, isTrue);
        Focus.of(
          tester.element(
            find.descendant(of: device, matching: find.byType(Text)).first,
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(find.byType(RegistryEditorScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
}
