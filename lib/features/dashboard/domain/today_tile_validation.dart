const _todaySections = {'shopping', 'chores', 'calendar', 'notifications'};

/// Personal Today context is either absent (follow the shared selection) or a
/// complete bounded pair. Other tile types cannot smuggle these fields.
bool hasValidTodayTileFields(Map<String, dynamic> tile) {
  final section = tile['todaySection'];
  final query = tile['todayQuery'];
  if (tile['type'] != 'today') return section == null && query == null;
  if (section == null && query == null) return true;
  return section is String &&
      _todaySections.contains(section) &&
      query is String &&
      query.length <= 128 &&
      !query.contains(RegExp(r'[\x00-\x1f\x7f]'));
}
