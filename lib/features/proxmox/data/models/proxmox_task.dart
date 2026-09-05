import 'proxmox_values.dart';

class ProxmoxTask {
  const ProxmoxTask({
    required this.upid,
    required this.type,
    this.resourceId,
    this.user,
    this.status,
    this.startTimeSeconds,
    this.endTimeSeconds,
  });

  final String upid;
  final String type;
  final String? resourceId;
  final String? user;

  /// Absent while the task is still running; `'OK'` on success, otherwise
  /// an error message.
  final String? status;
  final int? startTimeSeconds;
  final int? endTimeSeconds;

  bool get isRunning => status == null;

  bool get isSuccess => status == 'OK';

  factory ProxmoxTask.fromJson(Map<String, dynamic> json) => ProxmoxTask(
    upid: proxmoxIdentity(json['upid']),
    type: json['type'] as String? ?? 'unknown',
    resourceId: json['id'] as String?,
    user: json['user'] as String?,
    status: json['status'] as String?,
    startTimeSeconds: proxmoxInteger(json['starttime']),
    endTimeSeconds: proxmoxInteger(json['endtime']),
  );
}
