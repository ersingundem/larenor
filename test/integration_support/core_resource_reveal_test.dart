import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/app_harness.dart';

void main() {
  testWidgets('reveals a loaded resource below the lazy sliver viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const resource = ValueKey('home-resource-fixture');
    const loaded = true;
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: 900)),
              SliverList.builder(itemCount: 1, itemBuilder: _resourceRow),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(resource), findsNothing);

    await revealCoreResource(
      tester,
      find.byKey(resource),
      loaded: () => loaded,
    );

    expect(find.byKey(resource), findsOneWidget);
  });
}

Widget _resourceRow(BuildContext context, int index) =>
    const SizedBox(key: ValueKey('home-resource-fixture'), height: 80);
