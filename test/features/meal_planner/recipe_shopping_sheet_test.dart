import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/meal_planner/data/recipe_shopping_handoff.dart';
import 'package:larenor/features/meal_planner/presentation/recipe_shopping_sheet.dart';
import 'package:larenor/features/today/data/today_actions.dart';
import 'package:larenor/features/today/domain/today_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

class _Source implements RecipeShoppingAuthoritySource {
  RecipeShoppingAuthorityFacts? facts = RecipeShoppingAuthorityFacts.core(
    coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    homeId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    accountId: 'cccccccccccccccccccccccccccccccc',
    sessionFamily: 1,
    endpointBaseUrl: 'https://core.invalid',
    runtimeIdentity: Object(),
    interactionEpoch: 1,
  );
  @override
  RecipeShoppingAuthorityFacts? read() => facts;
}

class _Actions implements TodayActions {
  final calls = <String>[];
  Completer<void>? pending;
  @override
  Future<void> addTodoBound(
    TodayTodoList list,
    String summary, {
    required bool Function() current,
    String? idempotencyKey,
    String? dueDate,
    DateTime? dueAt,
    String? description,
  }) async {
    if (!current()) throw StateError('stale');
    calls.add(summary);
    await pending?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _list = TodayTodoList(
  entityId: 'todo.shopping_list',
  title: 'Shopping',
  supportedFeatures: 1,
  available: true,
  items: TodayRead(value: []),
);

Future<void> _mount(
  WidgetTester tester, {
  required Locale locale,
  required Size size,
  required double scale,
  required _Source source,
  required _Actions actions,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        recipeShoppingAuthoritySourceProvider.overrideWithValue(source),
      ],
      child: CupertinoApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RecipeShoppingSheet(list: _list, actions: actions),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('recipe-title')), 'Soup');
  await tester.enterText(
    find.byKey(const ValueKey('recipe-base-servings')),
    '2',
  );
  await tester.enterText(
    find.byKey(const ValueKey('recipe-target-servings')),
    '4',
  );
  await tester.enterText(
    find.byKey(const ValueKey('recipe-ingredients')),
    '100 g Lentils\n1 l Water',
  );
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1200.0]) {
      testWidgets(
        '${locale.languageCode} ${width.toInt()} at 2x remains usable',
        (tester) async {
          final source = _Source(), actions = _Actions();
          await _mount(
            tester,
            locale: locale,
            size: Size(width, 900),
            scale: 2,
            source: source,
            actions: actions,
          );
          expect(tester.takeException(), isNull);
          final submit = find.byKey(const ValueKey('recipe-submit'));
          await tester.ensureVisible(submit);
          expect(tester.getSize(submit).height, greaterThanOrEqualTo(48));
          expect(
            find.text(
              locale.languageCode == 'tr'
                  ? 'Tarifi alışverişe ekle'
                  : 'Add recipe to shopping',
            ),
            findsOneWidget,
          );
        },
      );
    }
  }

  testWidgets('Enter submits and announces verified readback', (tester) async {
    final source = _Source(), actions = _Actions();
    await _mount(
      tester,
      locale: const Locale('en'),
      size: const Size(1200, 900),
      scale: 1,
      source: source,
      actions: actions,
    );
    await _fill(tester);
    final button = tester.widget<CupertinoButton>(
      find.byKey(const ValueKey('recipe-submit')),
    );
    button.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(actions.calls, ['200 g Lentils', '2 l Water']);
    expect(
      find.text('2 ingredients from Soup verified in Shopping.'),
      findsOneWidget,
    );
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('recipe-status')),
    );
    expect(semantics.flagsCollection.isLiveRegion, isTrue);
  });

  testWidgets('backgrounded late completion never reports success', (
    tester,
  ) async {
    final source = _Source(), actions = _Actions()..pending = Completer<void>();
    await _mount(
      tester,
      locale: const Locale('tr'),
      size: const Size(600, 900),
      scale: 1,
      source: source,
      actions: actions,
    );
    await _fill(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('recipe-submit')));
    await tester.tap(find.byKey(const ValueKey('recipe-submit')));
    await tester.pump();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    actions.pending!.complete();
    await tester.pump();
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }

    expect(find.textContaining('doğrulandı'), findsNothing);
    expect(actions.calls, hasLength(1));
  });

  testWidgets('48dp launcher opens the recipe handoff route', (tester) async {
    final source = _Source(), actions = _Actions();
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recipeShoppingAuthoritySourceProvider.overrideWithValue(source),
        ],
        child: CupertinoApp(
          locale: const Locale('tr'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: CupertinoPageScaffold(
            child: Center(
              child: RecipeShoppingLaunchButton(
                list: _list,
                actions: actions,
                enabled: true,
              ),
            ),
          ),
        ),
      ),
    );
    final launcher = find.byKey(
      const ValueKey('recipe-launch-todo.shopping_list'),
    );
    expect(tester.getSize(launcher).height, greaterThanOrEqualTo(48));
    await tester.tap(launcher);
    await tester.pumpAndSettle();
    expect(find.byType(RecipeShoppingSheet), findsOneWidget);
    expect(find.text('Tarifi alışverişe ekle'), findsOneWidget);
  });
}
