enum FairChoreAction { completed, deferred }

class FairChoreAuthority {
  const FairChoreAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionId,
    required this.routeId,
  });

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionId;
  final String routeId;

  @override
  bool operator ==(Object other) =>
      other is FairChoreAuthority &&
      other.coreId == coreId &&
      other.homeId == homeId &&
      other.accountId == accountId &&
      other.sessionId == sessionId &&
      other.routeId == routeId;

  @override
  int get hashCode =>
      Object.hash(coreId, homeId, accountId, sessionId, routeId);
}

class FairChoreTask {
  const FairChoreTask({
    required this.id,
    required this.title,
    required this.revision,
    required this.assigneeId,
    required this.dueAt,
  });

  final String id;
  final String title;
  final int revision;
  final String assigneeId;
  final DateTime dueAt;
}

class FairChorePage {
  FairChorePage(this.authority, List<FairChoreTask> tasks)
    : tasks = List.unmodifiable(tasks);

  final FairChoreAuthority authority;
  final List<FairChoreTask> tasks;
}

class FairChoreReceipt {
  const FairChoreReceipt({
    required this.authority,
    required this.commandId,
    required this.action,
    required this.task,
  });

  final FairChoreAuthority authority;
  final String commandId;
  final FairChoreAction action;
  final FairChoreTask task;
}

abstract interface class FairChoreApi {
  Future<FairChorePage> list(FairChoreAuthority authority);

  Future<FairChoreReceipt> complete(
    FairChoreAuthority authority, {
    required String taskId,
    required int expectedRevision,
    required String commandId,
  });

  Future<FairChoreReceipt> defer(
    FairChoreAuthority authority, {
    required String taskId,
    required int expectedRevision,
    required String commandId,
    required int days,
  });

  Future<FairChoreReceipt?> receipt(
    FairChoreAuthority authority,
    String commandId,
  );
}
