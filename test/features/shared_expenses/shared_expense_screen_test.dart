import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/shared_expenses/data/shared_expense_controller.dart';
import 'package:larenor/features/shared_expenses/domain/shared_expense_models.dart';
import 'package:larenor/features/shared_expenses/presentation/shared_expense_screen.dart';

import 'shared_expense_controller_test.dart';

Future<void> pumpExpenseScreen(
  WidgetTester tester, {
  required Size size,
  required SharedExpenseStrings strings,
  required FakeSharedExpenseApi api,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = SharedExpenseController(
    api,
    commandIds: () => 'ui-create',
  );
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size, textScaler: const TextScaler.linear(2)),
      child: CupertinoApp(
        home: SharedExpenseScreen(
          controller: controller,
          authority: expenseAuthorityA,
          strings: strings,
        ),
      ),
    ),
  );
  api.snapshots.single.complete(
    snapshot(expenseAuthorityA, records: [record()]),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('EN/TR 600/1200 @2x previews split and keeps 48dp actions', (
    tester,
  ) async {
    for (final sample in [
      (const Size(600, 900), SharedExpenseStrings.tr),
      (const Size(1200, 800), SharedExpenseStrings.en),
    ]) {
      final api = FakeSharedExpenseApi();
      await pumpExpenseScreen(
        tester,
        size: sample.$1,
        strings: sample.$2,
        api: api,
      );
      await tester.enterText(
        find.byKey(const ValueKey('expense-title')),
        'Market',
      );
      await tester.enterText(
        find.byKey(const ValueKey('expense-amount')),
        '100,00',
      );
      await tester.pump();
      expect(
        find.textContaining('33${sample.$2.decimalSeparator}34'),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('expense-create'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('expense-export'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'history and participant-filtered export are read-only accessible surfaces',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final api = FakeSharedExpenseApi()
        ..exported = ExpenseExport(expenseAuthorityA, 4, [record()]);
      await pumpExpenseScreen(
        tester,
        size: const Size(1200, 800),
        strings: SharedExpenseStrings.en,
        api: api,
      );
      expect(find.text('Ortak market'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('expense-export')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('expense-export-result')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('expense-export'))),
        matchesSemantics(
          label: 'Read my expense export',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      expect(api.createCalls, 0);
      semantics.dispose();
    },
  );
}
