import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// Layout-only units, independent of live entity state and saved schema.
@immutable
class DashboardGridSpan {
  const DashboardGridSpan(this.columns, this.rows)
    : assert(columns >= 1 && columns <= 6),
      assert(rows >= 1 && rows <= 4);
  final int columns;
  final int rows;

  @override
  bool operator ==(Object other) =>
      other is DashboardGridSpan &&
      columns == other.columns &&
      rows == other.rows;
  @override
  int get hashCode => Object.hash(columns, rows);
}

/// A variable-span sliver that builds visible cards only. Source order stays
/// top-to-bottom/leading-to-trailing: later cards never jump into older holes.
/// Geometry is computed once per width; scroll lookups use binary searches.
class DashboardGridDelegate extends SliverGridDelegate {
  DashboardGridDelegate({
    required List<DashboardGridSpan> spans,
    required this.rowExtent,
    this.minimumColumnExtent = 140,
    this.spacing = 12,
    this.maximumColumns = 6,
  }) : spans = List.unmodifiable(spans),
       assert(rowExtent > 0 && rowExtent.isFinite),
       assert(minimumColumnExtent > 0 && minimumColumnExtent.isFinite),
       assert(spacing >= 0 && spacing.isFinite),
       assert(maximumColumns >= 1 && maximumColumns <= 12);

  final List<DashboardGridSpan> spans;
  final double rowExtent;
  final double minimumColumnExtent;
  final double spacing;
  final int maximumColumns;
  double? _lastExtent;
  bool? _lastReverse;
  _DashboardGridLayout? _lastLayout;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final extent = constraints.crossAxisExtent;
    final reverse = axisDirectionIsReversed(constraints.crossAxisDirection);
    if (_lastExtent == extent && _lastReverse == reverse) return _lastLayout!;
    final columns = ((extent + spacing) / (minimumColumnExtent + spacing))
        .floor()
        .clamp(1, maximumColumns);
    final cellExtent = math.max(
      0.0,
      (extent - spacing * (columns - 1)) / columns,
    );
    final occupied = <int, int>{};
    final geometry = <SliverGridGeometry>[];
    final trailing = <double>[];
    var cursor = 0;
    var maximumTrailing = 0.0;
    for (final span in spans) {
      final width = math.min(columns, span.columns);
      final mask = (1 << width) - 1;
      int row;
      int column;
      while (true) {
        row = cursor ~/ columns;
        column = cursor % columns;
        var fits = column + width <= columns;
        if (fits) {
          for (var dy = 0; dy < span.rows; dy++) {
            if (((occupied[row + dy] ?? 0) & (mask << column)) != 0) {
              fits = false;
              break;
            }
          }
        }
        if (fits) break;
        cursor++;
      }
      for (var dy = 0; dy < span.rows; dy++) {
        occupied[row + dy] = (occupied[row + dy] ?? 0) | (mask << column);
      }
      // Completed rows cannot be revisited; keep packing memory bounded.
      occupied.removeWhere((key, _) => key < row);
      final childCrossExtent = width * cellExtent + (width - 1) * spacing;
      final leading = column * (cellExtent + spacing);
      final child = SliverGridGeometry(
        scrollOffset: row * (rowExtent + spacing),
        crossAxisOffset: reverse
            ? extent - leading - childCrossExtent
            : leading,
        mainAxisExtent: span.rows * rowExtent + (span.rows - 1) * spacing,
        crossAxisExtent: childCrossExtent,
      );
      geometry.add(child);
      maximumTrailing = math.max(maximumTrailing, child.trailingScrollOffset);
      trailing.add(maximumTrailing);
      cursor += width;
    }
    _lastExtent = extent;
    _lastReverse = reverse;
    return _lastLayout = _DashboardGridLayout(geometry, trailing);
  }

  @override
  bool shouldRelayout(covariant DashboardGridDelegate oldDelegate) =>
      rowExtent != oldDelegate.rowExtent ||
      minimumColumnExtent != oldDelegate.minimumColumnExtent ||
      spacing != oldDelegate.spacing ||
      maximumColumns != oldDelegate.maximumColumns ||
      !listEquals(spans, oldDelegate.spans);
}

class _DashboardGridLayout extends SliverGridLayout {
  const _DashboardGridLayout(this.geometry, this.trailing);
  final List<SliverGridGeometry> geometry;
  final List<double> trailing;

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) => geometry[index];

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    if (geometry.isEmpty) return 0;
    var low = 0;
    var high = trailing.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (trailing[mid] < scrollOffset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return math.min(low, geometry.length - 1);
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    if (geometry.isEmpty) return 0;
    var low = 0;
    var high = geometry.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (geometry[mid].scrollOffset <= scrollOffset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return math.max(0, low - 1);
  }

  @override
  double computeMaxScrollOffset(int childCount) =>
      childCount == 0 || geometry.isEmpty
      ? 0
      : trailing[math.min(childCount, trailing.length) - 1];
}
