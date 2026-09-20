import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/cooking_assistant/data/cooking_session_controller.dart';
import 'package:oikos/features/cooking_assistant/domain/cooking_session.dart';
import 'package:oikos/features/cooking_assistant/presentation/cooking_session_screen.dart';

final class _Gateway implements CookingSessionGateway {
  CookingSession value;
  _Gateway(this.value);

  @override
  Future<CookingSession> move({
    required String sessionId,
    required int expectedRevision,
    required int step,
  }) async => value = value.copyWith(
    revision: expectedRevision + 1,
    currentStep: step,
  );
}

CookingSession _session() => const CookingSession(
  id: 'session-1',
  accountId: 'account-a',
  recipeId: 'recipe-1',
  recipeRevision: 3,
  revision: 1,
  title: 'Soup',
  steps: ['Prepare', 'Cook', 'Rest'],
  currentStep: 0,
);

Future<void> pump(
  WidgetTester tester, {
  required double width,
  required CookingAssistantStrings strings,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final value = _session();
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 900),
        textScaler: const TextScaler.linear(2),
      ),
      child: CookingSessionScreen(
        controller: CookingSessionController(
          gateway: _Gateway(value), initial: value, isCurrent: () => true),
        strings: strings,
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  for (final width in const [600.0, 1200.0]) {
    testWidgets('EN/TR tablet layout is readable at 2x and controls are 48dp',
        (tester) async {
      for (final strings in [CookingAssistantStrings.en, CookingAssistantStrings.tr]) {
        await pump(tester, width: width, strings: strings);
        expect(find.text(strings.stepProgress(1, 3)), findsOneWidget);
        final next = find.byKey(const Key('cooking-next'));
        final previous = find.byKey(const Key('cooking-previous'));
        expect(tester.getSize(next).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(previous).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('keyboard and TalkBack expose previous and next', (tester) async {
    await pump(tester, width: 1200, strings: CookingAssistantStrings.en);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(CookingAssistantStrings.en.next), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text(CookingAssistantStrings.en.stepProgress(2, 3)), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.text(CookingAssistantStrings.en.stepProgress(1, 3)), findsOneWidget);
    semantics.dispose();
  });
}
