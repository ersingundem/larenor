import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/shared/widgets/larenor_brand.dart';

void main() {
  testWidgets('compact sidebar brand wraps its real motto at large text size', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Center(
              child: SizedBox(width: 194, child: LarenorBrand(compact: true)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Larenor Client'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      'Unus Lar, omnem domum servat.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('centered brand fits a narrow phone with large text', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Center(
              child: SizedBox(width: 288, child: LarenorBrand(centered: true)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LarenorLogo), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
