import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk_remote/runtime/managed_tablet_runtime_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('runtime scope unmount does not read a disposed widget ref', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ManagedTabletRuntimeScope(child: SizedBox()),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
