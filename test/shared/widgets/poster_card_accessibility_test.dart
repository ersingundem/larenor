import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/shared/widgets/poster_card.dart';

void main() {
  for (final interruption in [
    'idle',
    'hidden',
    'background',
    'covered',
    'reparented',
    'disposed',
  ]) {
    testWidgets(
      'poster rejects old callback after $interruption and current keyboard action resumes',
      (tester) async {
        var opens = 0;
        void open() => opens++;
        final first = AppInteractionController();
        final second = AppInteractionController();
        var controller = first;
        final navigator = GlobalKey<NavigatorState>();
        var visible = true;
        Widget app() => AppInteractionScope(
          controller: controller,
          child: CupertinoApp(
            navigatorKey: navigator,
            home: CupertinoPageScaffold(
              child: TickerMode(
                enabled: visible,
                child: Center(
                  child: PosterCard(title: 'A Quiet Orbit', onTap: open),
                ),
              ),
            ),
          ),
        );
        CupertinoButton button() => tester.widget<CupertinoButton>(
          find.descendant(
            of: find.byType(PosterCard),
            matching: find.byType(CupertinoButton),
          ),
        );
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        final oldCallback = button().onPressed!;
        try {
          switch (interruption) {
            case 'idle':
              first.setActive(false);
              oldCallback();
              expect(opens, 0);
              first.setActive(true);
              await tester.pump();
            case 'hidden':
              visible = false;
              await tester.pumpWidget(app());
              oldCallback();
              expect(opens, 0);
              expect(button().onPressed, isNull);
              visible = true;
              await tester.pumpWidget(app());
            case 'background':
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              await tester.pump();
              expect(button().onPressed, isNull);
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.hidden,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.paused,
              );
              oldCallback();
              expect(opens, 0);
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.hidden,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );
              await tester.pump();
            case 'covered':
              navigator.currentState!.push(
                CupertinoPageRoute<void>(
                  builder: (_) =>
                      const CupertinoPageScaffold(child: Text('Other route')),
                ),
              );
              await tester.pumpAndSettle();
              oldCallback();
              expect(opens, 0);
              navigator.currentState!.pop();
              await tester.pumpAndSettle();
            case 'reparented':
              controller = second;
              await tester.pumpWidget(app());
            case 'disposed':
              await tester.pumpWidget(const SizedBox.shrink());
          }
          oldCallback();
          expect(opens, 0);
          if (interruption == 'disposed') await tester.pumpWidget(app());
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(opens, 1);
        } finally {
          if (tester.binding.lifecycleState == AppLifecycleState.paused) {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
          }
          if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
          }
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          first.dispose();
          second.dispose();
        }
      },
    );
  }

  testWidgets('poster exposes one named button and keyboard activation', (
    tester,
  ) async {
    var opens = 0;
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        CupertinoApp(
          theme: larenorTheme(),
          home: CupertinoPageScaffold(
            child: Center(
              child: PosterCard(
                title: 'A Quiet Orbit',
                overlay: const Text('Available'),
                onTap: () => opens++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final nodes =
          tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
      final matches = <SemanticsNode>[];
      void visit(SemanticsNode node) {
        if (node.getSemanticsData().hasFlag(SemanticsFlag.isButton) &&
            node.getSemanticsData().label.contains('A Quiet Orbit'))
          matches.add(node);
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(nodes);
      expect(matches, hasLength(1));
      expect(matches.single.getSemanticsData().label, contains('Available'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(opens, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(opens, 2);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  });
}
