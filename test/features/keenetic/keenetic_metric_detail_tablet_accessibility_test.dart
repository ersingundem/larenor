import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/domain/tile_config.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';
import 'package:larenor/features/keenetic/presentation/keenetic_metric_detail_screen.dart';
import 'package:larenor/features/keenetic/providers/keenetic_providers.dart';
import 'package:larenor/features/keenetic/providers/keenetic_telemetry_controller.dart';
import 'package:larenor/features/keenetic/providers/keenetic_telemetry_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

const _tile = TileConfig(
  id: 'router',
  type: TileType.keenetic,
  x: 0,
  y: 0,
  width: 2,
  height: 2,
);

class _Connection extends KeeneticConnection {
  @override
  Future<KeeneticConfig?> build() async => const KeeneticConfig(
    baseUrl: 'http://router.test',
    username: 'test',
    password: 'test',
  );
}

class _Controller extends KeeneticTelemetryController {
  _Controller() : super(client: null);

  int refreshes = 0;

  @override
  void refresh() => refreshes++;
}

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  required _Controller controller,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keeneticConnectionProvider.overrideWith(_Connection.new),
        keeneticTelemetryControllerProvider.overrideWithValue(controller),
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
        home: const KeeneticMetricDetailScreen(tile: _tile),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('$language metric refresh is accessible at ${width}px 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final controller = _Controller();
        addTearDown(controller.dispose);
        await _mount(
          tester,
          language: language,
          width: width,
          controller: controller,
        );

        expect(find.byType(ServiceRootScaffold), findsOneWidget);
        expect(find.byType(SettingsSection), findsOneWidget);
        expect(find.byType(SettingsActionTile), findsOneWidget);
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('keenetic-metric-header')),
              )
              .flagsCollection
              .isHeader,
          isTrue,
        );
        final refresh = find.byKey(const ValueKey('keenetic-metric-refresh'));
        expect(
          tester.widget<CupertinoButton>(refresh).minimumSize,
          const Size(48, 48),
        );
        expect(tester.getSemantics(refresh).flagsCollection.isButton, isTrue);

        Focus.of(
          tester.element(
            find.descendant(of: refresh, matching: find.byType(Text)).first,
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(controller.refreshes, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        semantics.dispose();
      });
    }
  }
}
