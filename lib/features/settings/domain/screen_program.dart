import 'dart:convert';

/// Local wall-clock recurrence. A wrapping rule belongs to its start weekday.
/// During DST folds both occurrences match; a skipped minute is never invented.
enum ScreenAwakeMode { inherit, keepAwake, systemTimeout }

class ScreenPolicy {
  const ScreenPolicy({required this.keepAwake, required this.dim});
  final bool keepAwake;
  final bool dim;
  static const released = ScreenPolicy(keepAwake: false, dim: false);
  @override
  bool operator ==(Object other) =>
      other is ScreenPolicy && keepAwake == other.keepAwake && dim == other.dim;
  @override
  int get hashCode => Object.hash(keepAwake, dim);
}

class ScreenProgramRule {
  ScreenProgramRule({
    required this.id,
    this.name = '',
    required Set<int> days,
    required this.startMinutes,
    required this.endMinutes,
    this.awake = ScreenAwakeMode.inherit,
    this.dim = false,
    this.enabled = true,
  }) : days = Set.unmodifiable(days);
  final String id, name;
  final Set<int> days;
  final int startMinutes, endMinutes;
  final ScreenAwakeMode awake;
  final bool dim, enabled;
  bool matches(DateTime wallTime) {
    if (!enabled || startMinutes == endMinutes) return false;
    final minute = wallTime.hour * 60 + wallTime.minute;
    if (startMinutes < endMinutes) {
      return days.contains(wallTime.weekday) &&
          minute >= startMinutes &&
          minute < endMinutes;
    }
    final previousWeekday = wallTime.weekday == 1 ? 7 : wallTime.weekday - 1;
    return (days.contains(wallTime.weekday) && minute >= startMinutes) ||
        (days.contains(previousWeekday) && minute < endMinutes);
  }

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'days': (days.toList()..sort()),
    'startMinutes': startMinutes,
    'endMinutes': endMinutes,
    'awake': awake.name,
    'dim': dim,
    'enabled': enabled,
  };
}

class ScreenProgram {
  ScreenProgram({
    this.enabled = false,
    List<ScreenProgramRule> rules = const [],
  }) : rules = List.unmodifiable(rules);
  static const preferenceKey = 'screen_program_v1';
  static const maxRules = 16;
  final bool enabled;
  final List<ScreenProgramRule> rules;

  ScreenPolicy evaluate(DateTime wallTime, {required bool defaultKeepAwake}) {
    var result = ScreenPolicy(keepAwake: defaultKeepAwake, dim: false);
    if (!enabled) return result;
    for (final rule in rules) {
      if (!rule.matches(wallTime)) continue;
      result = ScreenPolicy(
        keepAwake: switch (rule.awake) {
          ScreenAwakeMode.inherit => defaultKeepAwake,
          ScreenAwakeMode.keepAwake => true,
          ScreenAwakeMode.systemTimeout => false,
        },
        dim: rule.dim,
      );
    }
    return result;
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'enabled': enabled,
    'rules': rules.map((rule) => rule.toJson()).toList(),
  };
  String encode() {
    ScreenProgram.fromJson(toJson());
    return jsonEncode(toJson());
  }

  factory ScreenProgram.decode(String raw) {
    if (raw.length > 32768) {
      throw const FormatException('Invalid screen program');
    }
    return ScreenProgram.fromJson(jsonDecode(raw));
  }
  factory ScreenProgram.fromJson(Object? raw) {
    Never invalid() => throw const FormatException('Invalid screen program');
    if (raw is! Map ||
        raw.length != 3 ||
        raw['version'] is! int ||
        raw['version'] != 1 ||
        raw['enabled'] is! bool ||
        raw['rules'] is! List) {
      invalid();
    }
    final entries = raw['rules'] as List;
    if (entries.length > maxRules) invalid();
    final ids = <String>{};
    final rules = <ScreenProgramRule>[];
    for (final item in entries) {
      if (item is! Map ||
          item.length != 8 ||
          item['id'] is! String ||
          item['name'] is! String ||
          item['days'] is! List ||
          item['startMinutes'] is! int ||
          item['endMinutes'] is! int ||
          item['dim'] is! bool ||
          item['enabled'] is! bool) {
        invalid();
      }
      final id = item['id'] as String, name = item['name'] as String;
      final days = item['days'] as List;
      final start = item['startMinutes'] as int,
          end = item['endMinutes'] as int;
      final awake = ScreenAwakeMode.values
          .where((v) => v.name == item['awake'])
          .firstOrNull;
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id) ||
          !ids.add(id) ||
          name.length > 60 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
          days.isEmpty ||
          days.length > 7 ||
          days.toSet().length != days.length ||
          days.any((day) => day is! int || day < 1 || day > 7) ||
          start < 0 ||
          start >= 1440 ||
          end < 0 ||
          end > 1440 ||
          awake == null) {
        invalid();
      }
      // Equal endpoints are an inert legacy setting, never an accidental 24h rule.
      rules.add(
        ScreenProgramRule(
          id: id,
          name: name,
          days: days.cast<int>().toSet(),
          startMinutes: start,
          endMinutes: end,
          awake: awake,
          dim: item['dim'] as bool,
          enabled: item['enabled'] as bool,
        ),
      );
    }
    return ScreenProgram(enabled: raw['enabled'] as bool, rules: rules);
  }
  factory ScreenProgram.legacy({
    required int startMinutes,
    required int endMinutes,
    required bool dim,
    required bool systemTimeout,
  }) => ScreenProgram(
    enabled: dim || systemTimeout,
    rules: [
      ScreenProgramRule(
        id: 'legacy-night',
        days: {1, 2, 3, 4, 5, 6, 7},
        startMinutes: startMinutes,
        endMinutes: endMinutes,
        dim: dim,
        awake: systemTimeout
            ? ScreenAwakeMode.systemTimeout
            : ScreenAwakeMode.inherit,
      ),
    ],
  );
}
