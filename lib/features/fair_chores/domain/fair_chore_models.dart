enum FairChoreAction { completed, deferred }

class FairChoreAuthority {
  const FairChoreAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionId,
    required this.routeId,
    required this.membersRevision,
  });

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionId;
  final String routeId;
  final int membersRevision;

  factory FairChoreAuthority.fromJson(
    Map<String, dynamic> json, {
    required String routeId,
    required String coreId,
    required String homeId,
    required String accountId,
  }) {
    if (json.length != 6 || json['schemaVersion'] != 1) {
      throw const FormatException('invalid_authority');
    }
    String id(String key) {
      final value = json[key];
      if (value is! String ||
          value.length != 32 ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
        throw const FormatException('invalid_authority');
      }
      return value;
    }

    final actualCore = id('coreId');
    final actualHome = id('homeId');
    final actualAccount = id('accountId');
    final session = id('sessionId');
    final revision = json['membersRevision'];
    if (actualCore != coreId ||
        actualHome != homeId ||
        actualAccount != accountId ||
        revision is! int ||
        revision < 1 ||
        revision > 9223372036854775807) {
      throw const FormatException('authority_changed');
    }
    return FairChoreAuthority(
      coreId: actualCore,
      homeId: actualHome,
      accountId: actualAccount,
      sessionId: session,
      routeId: routeId,
      membersRevision: revision,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FairChoreAuthority &&
      other.coreId == coreId &&
      other.homeId == homeId &&
      other.accountId == accountId &&
      other.sessionId == sessionId &&
      other.routeId == routeId &&
      other.membersRevision == membersRevision;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionId,
    routeId,
    membersRevision,
  );
}

class FairChoreTask {
  const FairChoreTask({
    required this.id,
    required this.title,
    required this.revision,
    required this.assigneeId,
    required this.assigneeLabel,
    required this.dueAt,
  });

  factory FairChoreTask.fromJson(Map<String, dynamic> json) {
    if (json.length != 6) throw const FormatException('invalid_task');
    final id = json['id'];
    final title = json['title'];
    final revision = json['revision'];
    final assigneeId = json['assigneeId'];
    final assigneeLabel = json['assigneeLabel'];
    final dueAt = json['dueAt'];
    if (id is! String ||
        id.length != 32 ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        title is! String ||
        title.isEmpty ||
        title.length > 200 ||
        revision is! int ||
        revision < 1 ||
        assigneeId is! String ||
        assigneeId.length != 32 ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(assigneeId) ||
        assigneeLabel is! String ||
        assigneeLabel.isEmpty ||
        assigneeLabel.length > 128 ||
        dueAt is! num ||
        !dueAt.isFinite ||
        dueAt < 0) {
      throw const FormatException('invalid_task');
    }
    return FairChoreTask(
      id: id,
      title: title,
      revision: revision,
      assigneeId: assigneeId,
      assigneeLabel: assigneeLabel,
      dueAt: DateTime.fromMillisecondsSinceEpoch(
        (dueAt * 1000).round(),
        isUtc: true,
      ),
    );
  }

  final String id;
  final String title;
  final int revision;
  final String assigneeId;
  final String assigneeLabel;
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
    required this.eventId,
    required this.commandId,
    required this.action,
    required this.task,
  });

  final FairChoreAuthority authority;
  final String eventId;
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
