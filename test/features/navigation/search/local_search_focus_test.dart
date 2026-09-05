import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/core/app_interaction_scope.dart';
import 'package:larenor/features/navigation/search/domain/local_search_index.dart';
import 'package:larenor/features/navigation/search/presentation/local_search_screen.dart';
import 'package:larenor/features/navigation/search/providers/local_search_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Index extends LocalSearchIndexController {
  @override
  LocalSearchIndex build() => LocalSearchIndex.build();
}

Future<void> _mount(
  WidgetTester tester, {
  bool autofocus = false,
  AppInteractionController? interaction,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final controller = interaction ?? AppInteractionController();
  if (interaction == null) addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [localSearchIndexProvider.overrideWith(_Index.new)],
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (_, child) =>
            AppInteractionScope(controller: controller, child: child!),
        home: Builder(
          builder: (context) => CupertinoPageScaffold(
            child: CupertinoButton(
              child: const Text('Open'),
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => LocalSearchScreen(
                    autofocus: autofocus,
                    onOpenTarget: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

FocusNode _focus(WidgetTester tester) => tester
    .widget<CupertinoSearchTextField>(find.byType(CupertinoSearchTextField))
    .focusNode!;
Future<void> _ctrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  testWidgets(
    'touch navigation does not focus text; Ctrl+K focuses and refocuses without stacking',
    (tester) async {
      await _mount(tester);
      expect(_focus(tester).hasFocus, isFalse);
      await _ctrlK(tester);
      expect(_focus(tester).hasFocus, isTrue);
      _focus(tester).unfocus();
      await tester.pump();
      expect(_focus(tester).hasFocus, isFalse);
      await _ctrlK(tester);
      expect(_focus(tester).hasFocus, isTrue);
      expect(find.byType(LocalSearchScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'keyboard navigation autofocuses and Escape returns without any selection',
    (tester) async {
      await _mount(tester, autofocus: true);
      expect(_focus(tester).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(find.byType(LocalSearchScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'inactive global interaction blocks autofocus and shortcut navigation',
    (tester) async {
      final controller = AppInteractionController(active: false);
      addTearDown(controller.dispose);
      await _mount(tester, autofocus: true, interaction: controller);
      expect(_focus(tester).hasFocus, isFalse);
      await _ctrlK(tester);
      expect(_focus(tester).hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(LocalSearchScreen), findsOneWidget);
      controller.setActive(true);
      await tester.pump();
      await _ctrlK(tester);
      expect(_focus(tester).hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'a root modal keeps focus and is not bypassed by search shortcuts',
    (tester) async {
      await _mount(tester, autofocus: true);
      final context = tester.element(find.byType(LocalSearchScreen));
      final modalFocus = FocusNode();
      addTearDown(modalFocus.dispose);
      showCupertinoDialog<void>(
        context: context,
        builder: (_) => CupertinoAlertDialog(
          title: const Text('Confirm'),
          content: Focus(
            autofocus: true,
            focusNode: modalFocus,
            child: const Text('Pending'),
          ),
          actions: [
            CupertinoDialogAction(onPressed: () {}, child: const Text('Safe')),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(modalFocus.hasFocus, isTrue);
      await _ctrlK(tester);
      expect(modalFocus.hasFocus, isTrue);
      expect(_focus(tester).hasFocus, isFalse);
      expect(find.text('Confirm'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
