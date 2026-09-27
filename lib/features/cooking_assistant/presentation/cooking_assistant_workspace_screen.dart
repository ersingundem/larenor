import 'package:flutter/material.dart';

import '../data/cooking_session_controller.dart';
import '../data/cooking_timers_controller.dart';
import '../data/ingredient_deduction_controller.dart';
import 'cooking_session_screen.dart';
import 'cooking_timers_screen.dart';
import 'ingredient_deduction_card.dart';

@immutable
final class CookingWorkspaceStrings {
  const CookingWorkspaceStrings({
    required this.steps,
    required this.timers,
    required this.ingredients,
  });

  static const en = CookingWorkspaceStrings(
    steps: 'Steps',
    timers: 'Timers',
    ingredients: 'Ingredients',
  );
  static const tr = CookingWorkspaceStrings(
    steps: 'Adımlar',
    timers: 'Zamanlayıcılar',
    ingredients: 'Malzemeler',
  );

  final String steps;
  final String timers;
  final String ingredients;
}

/// Adaptive cooking workspace. Wide windows keep steps and timers visible at
/// the same time; compact windows preserve each controller in an IndexedStack.
/// The ingredient deduction remains an explicit review/confirm surface.
class CookingAssistantWorkspaceScreen extends StatefulWidget {
  const CookingAssistantWorkspaceScreen({
    super.key,
    required this.sessionController,
    required this.timersController,
    required this.workspaceStrings,
    required this.sessionStrings,
    required this.timerStrings,
    this.deductionController,
    this.deductionStrings = IngredientDeductionStrings.en,
  });

  final CookingSessionController sessionController;
  final CookingTimersController timersController;
  final IngredientDeductionController? deductionController;
  final CookingWorkspaceStrings workspaceStrings;
  final CookingAssistantStrings sessionStrings;
  final CookingTimerStrings timerStrings;
  final IngredientDeductionStrings deductionStrings;

  @override
  State<CookingAssistantWorkspaceScreen> createState() =>
      _CookingAssistantWorkspaceScreenState();
}

class _CookingAssistantWorkspaceScreenState
    extends State<CookingAssistantWorkspaceScreen> {
  int _section = 0;

  List<Widget> _sections() => [
    CookingSessionScreen(
      controller: widget.sessionController,
      strings: widget.sessionStrings,
    ),
    CookingTimersScreen(
      controller: widget.timersController,
      strings: widget.timerStrings,
    ),
    if (widget.deductionController case final controller?)
      Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: IngredientDeductionCard(
              controller: controller,
              strings: widget.deductionStrings,
            ),
          ),
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final sections = _sections();
    if (_section >= sections.length) _section = 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1180) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 3, child: sections[0]),
              const VerticalDivider(width: 1),
              Expanded(flex: 2, child: sections[1]),
              if (sections.length == 3) ...[
                const VerticalDivider(width: 1),
                Expanded(flex: 2, child: sections[2]),
              ],
            ],
          );
        }
        final strings = widget.workspaceStrings;
        return Scaffold(
          body: IndexedStack(index: _section, children: sections),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _section,
            onDestinationSelected: (value) => setState(() => _section = value),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.menu_book_outlined),
                label: strings.steps,
              ),
              NavigationDestination(
                icon: const Icon(Icons.timer_outlined),
                label: strings.timers,
              ),
              if (sections.length == 3)
                NavigationDestination(
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: strings.ingredients,
                ),
            ],
          ),
        );
      },
    );
  }
}
