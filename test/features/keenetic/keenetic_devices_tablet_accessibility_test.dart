import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_device.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_devices_screen.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

class _Connection extends KeeneticConnection {
  @override
  Future<KeeneticConfig?> build() async => const KeeneticConfig(
    baseUrl: 'http://router.test',
    username: 'test',
    password: 'test',
  );
}

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  required void Function() onBuild,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keeneticConnectionProvider.overrideWith(_Connection.new),
        keeneticClientProvider.overrideWith((ref) async => null),
        keeneticDevicesProvider.overrideWith((ref) async {
          onBuild();
          return const [
            KeeneticDevice(
              mac: 'AA:BB:CC:DD:EE:01',
              name: 'Living room tablet',
              ip: '192.168.1.40',
              active: true,
              registered: true,
            ),
          ];
        }),
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
        home: const KeeneticDevicesScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets(
        '$language Keenetic devices refresh is accessible at ${width}px 2x',
        (tester) async {
          final semantics = tester.ensureSemantics();
          var builds = 0;
          await _mount(
            tester,
            language: language,
            width: width,
            onBuild: () => builds++,
          );

          expect(find.byType(ServiceRootScaffold), findsOneWidget);
          expect(find.byType(SettingsSection), findsNWidgets(2));
          expect(find.byType(SettingsActionTile), findsOneWidget);
          expect(
            tester
                .getSemantics(
                  find.byKey(
                    const ValueKey('keenetic-devices-controls-header'),
                  ),
                )
                .flagsCollection
                .isHeader,
            isTrue,
          );
          final refresh = find.byKey(
            const ValueKey('keenetic-devices-refresh'),
          );
          expect(
            tester.widget<CupertinoButton>(refresh).minimumSize,
            const Size(48, 48),
          );
          expect(tester.getSemantics(refresh).flagsCollection.isButton, isTrue);
          expect(
            tester
                .getSemantics(
                  find.byKey(
                    const ValueKey('keenetic-device-AA:BB:CC:DD:EE:01'),
                  ),
                )
                .rect
                .height,
            greaterThanOrEqualTo(48),
          );

          Focus.of(
            tester.element(
              find.descendant(of: refresh, matching: find.byType(Text)).first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();

          expect(builds, 2);
          expect(tester.takeException(), isNull);
          semantics.dispose();
        },
      );
    }
  }
}
