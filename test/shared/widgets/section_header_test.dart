import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/theme.dart';
import 'package:larenor/shared/widgets/section_header.dart';

void main() {
  for (final title in ['Kitchen', 'Mutfak']) {
    for (final sliver in [false, true]) {
      for (final trailing in [false, true]) {
        testWidgets(
          '$title heading stays separate from its action (sliver=$sliver trailing=$trailing)',
          (tester) async {
            final semantics = tester.ensureSemantics();
            addTearDown(semantics.dispose);
            tester.view.physicalSize = const Size(600, 360);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            var actions = 0;
            final action = trailing
                ? CupertinoButton(
                    onPressed: () => actions++,
                    child: const Text('See all'),
                  )
                : null;
            await tester.pumpWidget(
              CupertinoApp(
                theme: larenorTheme(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(2)),
                  child: child!,
                ),
                home: CupertinoPageScaffold(
                  child: sliver
                      ? CustomScrollView(
                          slivers: [
                            SliverSectionHeader(title: title, trailing: action),
                          ],
                        )
                      : SectionHeader(title: title, trailing: action),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final heading = tester.getSemantics(find.text(title));
            expect(
              heading,
              isSemantics(
                label: title,
                isHeader: true,
                isButton: false,
                hasTapAction: false,
              ),
            );
            if (trailing) {
              final button = tester.getSemantics(find.text('See all'));
              expect(button.id, isNot(heading.id));
              expect(
                button,
                isSemantics(
                  label: 'See all',
                  isHeader: false,
                  isButton: true,
                  hasTapAction: true,
                ),
              );
              await tester.tap(find.text('See all'));
              expect(actions, 1);
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
