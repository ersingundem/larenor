import 'package:flutter/foundation.dart';

@immutable
final class CookingTimerAuthority {
  const CookingTimerAuthority({
    required this.accountId,
    required this.recipeSessionId,
    required this.epoch,
  });
  final String accountId;
  final String recipeSessionId;
  final int epoch;
}

@immutable
final class CookingTimer {
  const CookingTimer({
    required this.id,
    required this.accountId,
    required this.recipeSessionId,
    required this.label,
    required this.deadlineWall,
    required this.revision,
    required this.notified,
    required this.acknowledged,
  });
  final String id;
  final String accountId;
  final String recipeSessionId;
  final String label;
  final Duration deadlineWall;
  final int revision;
  final bool notified;
  final bool acknowledged;

  CookingTimer copyWith({int? revision, bool? notified, bool? acknowledged}) =>
      CookingTimer(
        id: id,
        accountId: accountId,
        recipeSessionId: recipeSessionId,
        label: label,
        deadlineWall: deadlineWall,
        revision: revision ?? this.revision,
        notified: notified ?? this.notified,
        acknowledged: acknowledged ?? this.acknowledged,
      );
}
