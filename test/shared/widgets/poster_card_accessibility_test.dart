import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/shared/widgets/poster_card.dart';

void main() {
  testWidgets('poster exposes one named button and keyboard activation', (
    tester,
  ) async {
    var opens = 0;
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);
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
  });
}
