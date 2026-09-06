import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/single_element_ready.dart';

final _ready = Provider<bool>((_) => false);

class _Target extends StatelessWidget {
  const _Target();
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  testWidgets(
    'mounted readiness survives empty, pending, absent and ready frames',
    (tester) async {
      var calls = 0;
      final observed = <Element>[];
      bool condition(Element element) {
        calls++;
        observed.add(element);
        expect(element.mounted, isTrue);
        return ProviderScope.containerOf(element, listen: false).read(_ready);
      }

      Future<void> mount({bool present = false, bool ready = false}) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [_ready.overrideWithValue(ready)],
            child: present ? const _Target() : const SizedBox.shrink(),
          ),
        );
      }

      final target = find.byType(_Target);
      await mount();
      expect(singleElementReady(target, condition), isFalse);
      expect(calls, 0);
      await mount(present: true);
      expect(singleElementReady(target, condition), isFalse);
      expect(calls, 1);
      final previous = observed.single;
      await mount();
      expect(previous.mounted, isFalse);
      expect(singleElementReady(target, condition), isFalse);
      expect(calls, 1);
      await mount(present: true, ready: true);
      expect(singleElementReady(target, condition), isTrue);
      expect(calls, 2);
      expect(observed.last, isNot(same(previous)));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'duplicate mounted targets are not ready and never evaluate the condition',
    (tester) async {
      await tester.pumpWidget(const Column(children: [_Target(), _Target()]));
      var calls = 0;
      expect(
        singleElementReady(find.byType(_Target), (_) {
          calls++;
          return true;
        }),
        isFalse,
      );
      expect(calls, 0);
    },
  );
  testWidgets('single mounted target condition failures still propagate', (
    tester,
  ) async {
    await tester.pumpWidget(const _Target());
    final error = StateError('synthetic-condition-failure');
    expect(
      () => singleElementReady(find.byType(_Target), (_) => throw error),
      throwsA(same(error)),
    );
  });
}
