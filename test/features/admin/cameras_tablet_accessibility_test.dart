import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/admin/presentation/camera_viewer_screen.dart';
import 'package:larenor/features/admin/presentation/cameras_screen.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:larenor/shared/widgets/service_root_scaffold.dart';
import 'package:larenor/shared/widgets/settings_action_tile.dart';
import 'package:larenor/shared/widgets/settings_section.dart';

class _Entities extends Entities {
  @override
  Future<Map<String, HaEntity>> build() async => const {
    'camera.entry': HaEntity(
      entityId: 'camera.entry',
      state: 'idle',
      attributes: {'friendly_name': 'Entry camera'},
    ),
  };
}

Future<void> _mount(
  WidgetTester tester, {
  required String language,
  required double width,
  AppInteractionController? interaction,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [entitiesProvider.overrideWith(_Entities.new)],
      child: CupertinoApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) {
          final content = MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          );
          return interaction == null
              ? content
              : AppInteractionScope(controller: interaction, child: content);
        },
        home: const CamerasScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('captured camera action cannot cross entity authority', (
    tester,
  ) async {
    await _mount(tester, language: 'en', width: 600);
    final open = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('camera-camera.entry')),
        )
        .onPressed!;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CamerasScreen)),
    );

    container.invalidate(entitiesProvider);
    await tester.pumpAndSettle();
    open();
    await tester.pumpAndSettle();

    expect(find.byType(CameraViewerScreen), findsNothing);
  });

  testWidgets('inactive tablet releases cameras and rejects old navigation', (
    tester,
  ) async {
    final interaction = AppInteractionController();
    addTearDown(interaction.dispose);
    await _mount(tester, language: 'en', width: 600, interaction: interaction);
    final open = tester
        .widget<CupertinoButton>(
          find.byKey(const ValueKey('camera-camera.entry')),
        )
        .onPressed!;

    interaction.setActive(false);
    await tester.pumpAndSettle();
    open();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('camera-camera.entry')), findsNothing);
    expect(find.byType(CameraViewerScreen), findsNothing);
  });

  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('$language camera action is accessible at ${width}px 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await _mount(tester, language: language, width: width);

        expect(find.byType(ServiceRootScaffold), findsOneWidget);
        expect(find.byType(SettingsSection), findsOneWidget);
        expect(find.byType(SettingsActionTile), findsOneWidget);
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('cameras-controls-header')),
              )
              .flagsCollection
              .isHeader,
          isTrue,
        );

        final camera = find.byKey(const ValueKey('camera-camera.entry'));
        await tester.ensureVisible(camera);
        expect(tester.getSize(camera).width, lessThanOrEqualTo(360));
        expect(
          tester.widget<CupertinoButton>(camera).minimumSize,
          const Size(48, 48),
        );
        expect(tester.getSemantics(camera).flagsCollection.isButton, isTrue);
        Focus.of(
          tester.element(
            find.descendant(of: camera, matching: find.byType(Text)).first,
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        expect(find.byType(CameraViewerScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
}
