import 'package:flutter/foundation.dart';

@immutable
final class CookingSession {
  const CookingSession({
    required this.id,
    required this.accountId,
    required this.recipeId,
    required this.recipeRevision,
    required this.revision,
    required this.title,
    required this.steps,
    required this.currentStep,
  }) : assert(steps.length > 0),
       assert(currentStep >= 0 && currentStep < steps.length);

  final String id;
  final String accountId;
  final String recipeId;
  final int recipeRevision;
  final int revision;
  final String title;
  final List<String> steps;
  final int currentStep;

  CookingSession copyWith({int? revision, int? currentStep}) => CookingSession(
    id: id,
    accountId: accountId,
    recipeId: recipeId,
    recipeRevision: recipeRevision,
    revision: revision ?? this.revision,
    title: title,
    steps: steps,
    currentStep: currentStep ?? this.currentStep,
  );
}
