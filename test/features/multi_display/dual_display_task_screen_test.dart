import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/multi_display/domain/dual_display_session.dart';
import 'package:larenor/features/multi_display/presentation/dual_display_task_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final class FakeTasks extends ChangeNotifier
    implements DualDisplayTaskViewModel {
  @override
  bool busy = false;
  @override
  String? failure;
  @override
  DisplayTopology? topology = DisplayTopology(
    revision: 7,
    surfaces: [
      DisplaySurface(
        displayId: 0,
        generation: 2,
        kind: DisplayKind.primary,
        widthPixels: 1600,
        heightPixels: 2560,
        densityDpi: 320,
        securePresentation: true,
      ),
      DisplaySurface(
        displayId: 4,
        generation: 5,
        kind: DisplayKind.external,
        widthPixels: 1920,
        heightPixels: 1080,
        densityDpi: 160,
        securePresentation: true,
      ),
    ],
  );
  @override
  DualDisplayState? state;
  int refreshes = 0, disconnects = 0;
  final activations = <(int, String)>[];

  @override
  Future<void> activate(DisplaySurface display, String routeId) async {
    activations.add((display.displayId, routeId));
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }

  @override
  Future<void> refresh() async {
    refreshes++;
  }
}

void main() {
  for (final language in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('$language $width 2x exposes accessible display tasks', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final tasks = FakeTasks();
        addTearDown(tasks.dispose);
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.localesTestValue = [Locale(language)];
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearLocalesTestValue);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await tester.pumpWidget(
          CupertinoApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DualDisplayTaskScreen(controller: tasks),
          ),
        );
        await tester.pump();

        final refresh = find.byKey(const ValueKey('dual-display-refresh'));
        final media = find.byKey(const ValueKey('dual-display-media-4'));
        final dashboard = find.byKey(
          const ValueKey('dual-display-dashboard-4'),
        );
        for (final action in [refresh, media, dashboard]) {
          await tester.ensureVisible(action);
          await tester.pump();
          expect(tester.getRect(action).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(action).flagsCollection.isButton, isTrue);
        }
        expect(find.byKey(const ValueKey('dual-display-primary-0')), findsOne);
        expect(find.byKey(const ValueKey('dual-display-external-4')), findsOne);
        expect(tester.takeException(), isNull);

        Focus.of(tester.element(media)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(tasks.activations, [(4, 'media.now-playing')]);
        semantics.dispose();
      });
    }
  }

  testWidgets('active task exposes explicit disconnect and live status', (
    tester,
  ) async {
    final tasks = FakeTasks();
    addTearDown(tasks.dispose);
    tasks.state = DualDisplayState.dual(
      status: DualDisplayStatus.active,
      topology: tasks.topology!,
      secondary: tasks.topology!.externalById(4)!,
      selection: DisplayRouteSelection(
        primaryRouteId: 'dashboard.home',
        secondaryRouteId: 'media.now-playing',
        secondarySensitivity: RouteSensitivity.public,
        focusOwner: DisplayOwner.primary,
        playerOwner: DisplayOwner.secondary,
      ),
    );
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DualDisplayTaskScreen(controller: tasks),
      ),
    );
    final disconnect = find.byKey(const ValueKey('dual-display-disconnect'));
    await tester.ensureVisible(disconnect);
    await tester.tap(disconnect);
    await tester.pump();
    expect(tasks.disconnects, 1);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('dual-display-status')))
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
  });
}
