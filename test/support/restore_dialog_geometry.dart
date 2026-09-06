import 'dart:ui' show SemanticsAction;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Inspect effective platform nodes, excluding children merged into a parent.
/// Keep all measured failures so both target and painted-font defects are visible.
List<String> restoreDialogGeometryFailures(
  WidgetTester tester, {
  required List<String> labels,
  required Finder cancel,
}) {
  final failures = <String>[];
  final nodes = <SemanticsNode>[];
  final root = tester.getSemantics(cancel).owner!.rootSemanticsNode!;
  void visit(SemanticsNode node) {
    if (!node.isMergedIntoParent) nodes.add(node);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  for (final label in labels) {
    final matches = nodes
        .where((n) => n.getSemanticsData().label == label && n.getSemanticsData().flagsCollection.isButton)
        .toList();
    if (matches.length != 1) {
      failures.add('$label: ${matches.length} effective nodes');
      continue;
    }
    final node = matches.single;
    final data = node.getSemanticsData();
    if (!data.flagsCollection.isButton ||
        !data.hasAction(SemanticsAction.tap)) {
      failures.add('$label: missing button/tap semantics');
    }
    if (node.rect.width + 1e-9 < 48 || node.rect.height + 1e-9 < 48) {
      failures.add(
        '$label: effective target ${node.rect.size}, expected >=48x48',
      );
    }
  }
  final taps = nodes
      .where(
        (n) =>
            n.getSemanticsData().flagsCollection.isButton &&
            n.getSemanticsData().hasAction(SemanticsAction.tap),
      )
      .length;
  if (taps != 2) failures.add('effective tap buttons: $taps, expected 2');
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: cancel, matching: find.byType(Text)).first,
  );
  final painted = MatrixUtils.transformRect(
    paragraph.getTransformTo(null),
    Offset.zero & paragraph.size,
  );
  final ratio = painted.height / paragraph.size.height;
  if ((ratio - 1).abs() > 1e-9) {
    failures.add(
      'short cancel label painted/layout height ratio $ratio, expected 1',
    );
  }
  return failures;
}
