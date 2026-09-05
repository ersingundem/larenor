import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/presentation/widgets/dashboard_grid_delegate.dart';

SliverConstraints constraints(double width, {bool rtl = false}) =>
    SliverConstraints(
      axisDirection: AxisDirection.down,
      growthDirection: GrowthDirection.forward,
      userScrollDirection: ScrollDirection.idle,
      scrollOffset: 0,
      precedingScrollExtent: 0,
      overlap: 0,
      remainingPaintExtent: 600,
      crossAxisExtent: width,
      crossAxisDirection: rtl ? AxisDirection.left : AxisDirection.right,
      viewportMainAxisExtent: 600,
      remainingCacheExtent: 850,
      cacheOrigin: 0,
    );

void main() {
  test('mixed spans fit, preserve reading order and mirror in RTL', () {
    final delegate = DashboardGridDelegate(
      spans: const [
        DashboardGridSpan(2, 2),
        DashboardGridSpan(1, 1),
        DashboardGridSpan(1, 2),
        DashboardGridSpan(2, 1),
      ],
      rowExtent: 100,
    );
    final layout = delegate.getLayout(constraints(460));
    final first = layout.getGeometryForChildIndex(0);
    expect(first.mainAxisExtent, 212);
    expect(first.crossAxisExtent, closeTo(302.6667, .001));
    expect(layout.getGeometryForChildIndex(1).scrollOffset, 0);
    expect(layout.getGeometryForChildIndex(2).scrollOffset, 112);
    expect(layout.getGeometryForChildIndex(3).scrollOffset, 224);
    expect(layout.computeMaxScrollOffset(4), 324);
    final reversed = delegate.getLayout(constraints(460, rtl: true));
    for (var i = 0; i < 4; i++) {
      final a = layout.getGeometryForChildIndex(i);
      final b = reversed.getGeometryForChildIndex(i);
      expect(b.scrollOffset, a.scrollOffset);
      expect(b.mainAxisExtent, a.mainAxisExtent);
      expect(
        b.crossAxisOffset,
        closeTo(460 - a.crossAxisOffset - a.crossAxisExtent, .001),
      );
    }
  });

  test('narrow windows clamp wide cards without horizontal overflow', () {
    final delegate = DashboardGridDelegate(
      spans: const [DashboardGridSpan(6, 2), DashboardGridSpan(2, 1)],
      rowExtent: 160,
    );
    for (final width in [0.0, 80.0, 280.0, 350.0, 1000.0]) {
      final layout = delegate.getLayout(constraints(width));
      for (var i = 0; i < 2; i++) {
        final child = layout.getGeometryForChildIndex(i);
        expect(child.crossAxisOffset, greaterThanOrEqualTo(0));
        expect(child.crossAxisExtent, greaterThanOrEqualTo(0));
        expect(
          child.crossAxisOffset + child.crossAxisExtent,
          lessThanOrEqualTo(width + .00001),
        );
      }
    }
  });

  test(
    '5000 mixed cards never overlap and scroll lookups retain tall cards',
    () {
      final spans = List.generate(
        5000,
        (i) => DashboardGridSpan(1 + i % 6, 1 + i % 4),
      );
      final delegate = DashboardGridDelegate(spans: spans, rowExtent: 100);
      final layout = delegate.getLayout(constraints(900));
      final cards = List.generate(5000, layout.getGeometryForChildIndex);
      final active = <SliverGridGeometry>[];
      var previousTop = 0.0;
      for (final child in cards) {
        expect(child.scrollOffset, greaterThanOrEqualTo(previousTop));
        previousTop = child.scrollOffset;
        active.removeWhere(
          (value) => value.trailingScrollOffset <= child.scrollOffset,
        );
        final rect = Rect.fromLTWH(
          child.crossAxisOffset,
          child.scrollOffset,
          child.crossAxisExtent,
          child.mainAxisExtent,
        );
        for (final other in active) {
          expect(
            rect.overlaps(
              Rect.fromLTWH(
                other.crossAxisOffset,
                other.scrollOffset,
                other.crossAxisExtent,
                other.mainAxisExtent,
              ),
            ),
            isFalse,
          );
        }
        active.add(child);
      }
      final max = layout.computeMaxScrollOffset(cards.length);
      for (var offset = 0.0; offset < max; offset += max / 100) {
        final minIndex = layout.getMinChildIndexForScrollOffset(offset);
        final maxIndex = layout.getMaxChildIndexForScrollOffset(offset + 600);
        for (var i = 0; i < cards.length; i++) {
          final card = cards[i];
          if (card.trailingScrollOffset > offset &&
              card.scrollOffset < offset + 600) {
            expect(i, inInclusiveRange(minIndex, maxIndex));
          }
        }
      }
      expect(identical(layout, delegate.getLayout(constraints(900))), isTrue);
    },
  );

  test('empty and equivalent layouts have stable geometry contracts', () {
    final empty = DashboardGridDelegate(spans: [], rowExtent: 100);
    final layout = empty.getLayout(constraints(350));
    expect(layout.computeMaxScrollOffset(0), 0);
    expect(layout.getMinChildIndexForScrollOffset(0), 0);
    expect(layout.getMaxChildIndexForScrollOffset(0), 0);
    expect(
      empty.shouldRelayout(DashboardGridDelegate(spans: [], rowExtent: 100)),
      isFalse,
    );
    expect(
      empty.shouldRelayout(DashboardGridDelegate(spans: [], rowExtent: 120)),
      isTrue,
    );
  });

  testWidgets(
    'sliver builds only visible cards, scrolls far and survives window resizing',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final built = <int>{};
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CustomScrollView(
            controller: controller,
            slivers: [
              SliverGrid(
                gridDelegate: DashboardGridDelegate(
                  spans: List.generate(
                    5000,
                    (i) => DashboardGridSpan(1 + i % 2, 1 + i % 2),
                  ),
                  rowExtent: 100,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  built.add(index);
                  return ColoredBox(
                    color: const Color(0xff0066cc),
                    child: Text('Card $index'),
                  );
                }, childCount: 5000),
              ),
            ],
          ),
        ),
      );
      expect(built.length, lessThan(40));
      controller.jumpTo(80000);
      await tester.pump();
      expect(built.length, lessThan(80));
      expect(built.any((index) => index > 300), isTrue);
      tester.view.physicalSize = const Size(1200, 800);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(built.length, lessThan(200));
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(find.text('Card 4999'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
