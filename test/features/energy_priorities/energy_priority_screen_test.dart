import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy_priorities/data/energy_priority_controller.dart';
import 'package:larenor/features/energy_priorities/presentation/energy_priority_screen.dart';

import 'energy_priority_controller_test.dart' as fixture;

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets('${locale.languageCode} $width 2x is accessible and bounded', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1100);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final controller = EnergyPriorityController(
          api: fixture.FakeEnergyPriorityApi(),
          isCurrent: () => true,
        );
        await tester.pumpWidget(
          CupertinoApp(
            locale: locale,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
              ),
              child: child!,
            ),
            home: EnergyPriorityScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('energy-reserve-percent')), findsOneWidget);
        final action = find.byKey(const ValueKey('energy-preview-action'));
        expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
        expect(
          tester.getSemantics(action).getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
        );
        controller.dispose();
      });
    }
  }
}
