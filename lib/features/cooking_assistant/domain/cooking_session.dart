import 'package:flutter/foundation.dart';

@immutable
final class CookingSession {
  const CookingSession({
    this.schemaVersion = 1,
    required this.id,
    required this.accountId,
    required this.recipeId,
    required this.recipeRevision,
    required this.revision,
    required this.title,
    required this.steps,
    required this.currentStep,
    this.cancelled = false,
  }) : assert(steps.length > 0),
       assert(currentStep >= 0 && currentStep < steps.length);

  final int schemaVersion;
  final String id;
  final String accountId;
  final String recipeId;
  final int recipeRevision;
  final int revision;
  final String title;
  final List<String> steps;
  final int currentStep;
  final bool cancelled;

  factory CookingSession.fromResponse(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.length != 2 ||
        raw['schemaVersion'] != 1 ||
        raw['session'] is! Map<String, dynamic>) {
      throw const FormatException('invalid_cooking_session');
    }
    final value = raw['session'] as Map<String, dynamic>;
    const keys = {
      'schemaVersion',
      'id',
      'accountId',
      'recipeId',
      'recipeRevision',
      'revision',
      'title',
      'steps',
      'currentStep',
      'cancelled',
    };
    if (value.length != keys.length ||
        !keys.every(value.containsKey) ||
        value['schemaVersion'] != 1 ||
        value['id'] is! String ||
        !_identity(value['id'] as String) ||
        value['accountId'] is! String ||
        !_identity(value['accountId'] as String) ||
        value['recipeId'] is! String ||
        !_identity(value['recipeId'] as String) ||
        value['recipeRevision'] is! int ||
        (value['recipeRevision'] as int) < 1 ||
        value['revision'] is! int ||
        (value['revision'] as int) < 1 ||
        value['title'] is! String ||
        (value['title'] as String).trim().isEmpty ||
        (value['title'] as String).length > 200 ||
        value['steps'] is! List ||
        value['currentStep'] is! int ||
        value['cancelled'] is! bool) {
      throw const FormatException('invalid_cooking_session');
    }
    final rawSteps = value['steps'] as List<dynamic>;
    if (rawSteps.isEmpty ||
        rawSteps.length > 100 ||
        rawSteps.any(
          (step) =>
              step is! String ||
              step.trim().isEmpty ||
              step.length > 2000 ||
              step != step.trim(),
        )) {
      throw const FormatException('invalid_cooking_session');
    }
    final step = value['currentStep'] as int;
    if (step < 0 || step >= rawSteps.length) {
      throw const FormatException('invalid_cooking_session');
    }
    return CookingSession(
      id: value['id'] as String,
      accountId: value['accountId'] as String,
      recipeId: value['recipeId'] as String,
      recipeRevision: value['recipeRevision'] as int,
      revision: value['revision'] as int,
      title: value['title'] as String,
      steps: List<String>.unmodifiable(rawSteps.cast<String>()),
      currentStep: step,
      cancelled: value['cancelled'] as bool,
    );
  }

  static List<CookingSession> listFromResponse(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.length != 2 ||
        raw['schemaVersion'] != 1 ||
        raw['sessions'] is! List) {
      throw const FormatException('invalid_cooking_session_list');
    }
    final rows = raw['sessions'] as List<dynamic>;
    if (rows.length > 100) {
      throw const FormatException('invalid_cooking_session_list');
    }
    final result = rows
        .map(
          (row) =>
              CookingSession.fromResponse({'schemaVersion': 1, 'session': row}),
        )
        .toList(growable: false);
    if (result.map((session) => session.id).toSet().length != result.length) {
      throw const FormatException('invalid_cooking_session_list');
    }
    return List.unmodifiable(result);
  }

  static bool _identity(String value) =>
      value.isNotEmpty &&
      value.length <= 128 &&
      RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(value);

  CookingSession copyWith({int? revision, int? currentStep, bool? cancelled}) =>
      CookingSession(
        schemaVersion: schemaVersion,
        id: id,
        accountId: accountId,
        recipeId: recipeId,
        recipeRevision: recipeRevision,
        revision: revision ?? this.revision,
        title: title,
        steps: steps,
        currentStep: currentStep ?? this.currentStep,
        cancelled: cancelled ?? this.cancelled,
      );
}
