enum FairChoreAction { created, completed, deferred, skipped }

class FairChoreAuthority {
  const FairChoreAuthority({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionId,
    required this.routeId,
    required this.membersRevision,
    this.canManage = false,
  });

  final String coreId;
  final String homeId;
  final String accountId;
  final String sessionId;
  final String routeId;
  final int membersRevision;
  final bool canManage;

  factory FairChoreAuthority.fromJson(
    Map<String, dynamic> json, {
    required String routeId,
    required String coreId,
    required String homeId,
    required String accountId,
  }) {
    if (json.length != 7 || json['schemaVersion'] != 2) {
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
    final canManage = json['canManage'];
    if (actualCore != coreId ||
        actualHome != homeId ||
        actualAccount != accountId ||
        revision is! int ||
        revision < 1 ||
        revision > 9223372036854775807 ||
        canManage is! bool) {
      throw const FormatException('authority_changed');
    }
    return FairChoreAuthority(
      coreId: actualCore,
      homeId: actualHome,
      accountId: actualAccount,
      sessionId: session,
      routeId: routeId,
      membersRevision: revision,
      canManage: canManage,
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
      other.membersRevision == membersRevision &&
      other.canManage == canManage;

  @override
  int get hashCode => Object.hash(
    coreId,
    homeId,
    accountId,
    sessionId,
    routeId,
    membersRevision,
    canManage,
  );
}

class FairChoreMember {
  const FairChoreMember({required this.id, required this.label});

  factory FairChoreMember.fromJson(Map<String, dynamic> json) {
    if (json.length != 3 || json['schemaVersion'] != 1) {
      throw const FormatException('invalid_member');
    }
    final id = json['id'];
    final label = json['label'];
    if (!_identity(id) ||
        label is! String ||
        label.isEmpty ||
        label.length > 128 ||
        label != label.trim() ||
        label.runes.any((value) => value < 32 || value == 127)) {
      throw const FormatException('invalid_member');
    }
    return FairChoreMember(id: id as String, label: label);
  }

  final String id;
  final String label;
}

class FairChorePermissions {
  const FairChorePermissions({
    required this.complete,
    required this.defer,
    required this.skip,
  });

  factory FairChorePermissions.fromJson(Map<String, dynamic> json) {
    if (json.length != 3 ||
        json['complete'] is! bool ||
        json['defer'] is! bool ||
        json['skip'] is! bool) {
      throw const FormatException('invalid_permissions');
    }
    return FairChorePermissions(
      complete: json['complete'] as bool,
      defer: json['defer'] as bool,
      skip: json['skip'] as bool,
    );
  }

  final bool complete;
  final bool defer;
  final bool skip;
}

class FairChoreTask {
  const FairChoreTask({
    required this.id,
    required this.title,
    required this.revision,
    required this.assigneeId,
    required this.assigneeLabel,
    required this.dueAt,
    this.timezone = 'UTC',
    this.intervalDays = 1,
    this.memberOrder = const [],
    this.permissions = const FairChorePermissions(
      complete: true,
      defer: true,
      skip: true,
    ),
  });

  factory FairChoreTask.fromJson(Map<String, dynamic> json) {
    if (json.length != 11 || json['schemaVersion'] != 2) {
      throw const FormatException('invalid_task');
    }
    final id = json['id'];
    final title = json['title'];
    final revision = json['revision'];
    final assigneeId = json['assigneeId'];
    final assigneeLabel = json['assigneeLabel'];
    final dueAt = json['dueAt'];
    final timezone = json['timezone'];
    final intervalDays = json['intervalDays'];
    final memberOrderJson = json['memberOrder'];
    if (!_identity(id) ||
        title is! String ||
        title.isEmpty ||
        title.length > 200 ||
        title != title.trim() ||
        title.runes.any((value) => value < 32 || value == 127) ||
        revision is! int ||
        revision < 1 ||
        !_identity(assigneeId) ||
        assigneeLabel is! String ||
        assigneeLabel.isEmpty ||
        assigneeLabel.length > 128 ||
        dueAt is! num ||
        !dueAt.isFinite ||
        dueAt < 0 ||
        dueAt > 253402300799 ||
        timezone is! String ||
        timezone.isEmpty ||
        timezone.length > 128 ||
        intervalDays is! int ||
        intervalDays < 1 ||
        intervalDays > 365 ||
        memberOrderJson is! List ||
        memberOrderJson.isEmpty ||
        memberOrderJson.length > 32) {
      throw const FormatException('invalid_task');
    }
    final memberOrder = memberOrderJson
        .map((value) => FairChoreMember.fromJson(_object(value)))
        .toList(growable: false);
    if (memberOrder.map((item) => item.id).toSet().length !=
        memberOrder.length) {
      throw const FormatException('invalid_task');
    }
    return FairChoreTask(
      id: id as String,
      title: title,
      revision: revision,
      assigneeId: assigneeId as String,
      assigneeLabel: assigneeLabel,
      dueAt: DateTime.fromMillisecondsSinceEpoch(
        (dueAt * 1000).round(),
        isUtc: true,
      ),
      timezone: timezone,
      intervalDays: intervalDays,
      memberOrder: List.unmodifiable(memberOrder),
      permissions: FairChorePermissions.fromJson(_object(json['permissions'])),
    );
  }

  final String id;
  final String title;
  final int revision;
  final String assigneeId;
  final String assigneeLabel;
  final DateTime dueAt;
  final String timezone;
  final int intervalDays;
  final List<FairChoreMember> memberOrder;
  final FairChorePermissions permissions;
}

class FairChorePage {
  FairChorePage(
    this.authority,
    List<FairChoreTask> tasks, {
    List<FairChoreMember> members = const [],
  }) : members = List.unmodifiable(members),
       tasks = List.unmodifiable(tasks);

  final FairChoreAuthority authority;
  final List<FairChoreMember> members;
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

abstract interface class FairChoreCommandApi implements FairChoreApi {
  Future<FairChoreReceipt> create(
    FairChoreAuthority authority, {
    required String commandId,
    required String title,
    required String timezone,
    required int intervalDays,
    required DateTime dueAt,
  });

  Future<FairChoreReceipt> skip(
    FairChoreAuthority authority, {
    required String taskId,
    required int expectedRevision,
    required String commandId,
  });
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('invalid_object');
  }
  return value;
}

bool _identity(Object? value) =>
    value is String &&
    value.length == 32 &&
    RegExp(r'^[0-9a-f]{32}$').hasMatch(value);
