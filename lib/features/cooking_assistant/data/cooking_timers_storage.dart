import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/cooking_timer.dart';
import 'cooking_timers_controller.dart';

typedef CookingTimerPreferencesLoader = Future<SharedPreferences> Function();

final class SharedPreferencesCookingTimerStore implements CookingTimerStore {
  SharedPreferencesCookingTimerStore({
    CookingTimerPreferencesLoader? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  static const _prefix = 'cooking_timers_v1_';
  static const _maximumRecords = 8;
  final CookingTimerPreferencesLoader _preferences;

  static String _key(String accountId, String recipeSessionId) {
    final scope = jsonEncode(['cooking-timers-v1', accountId, recipeSessionId]);
    return '$_prefix${sha256.convert(utf8.encode(scope))}';
  }

  @override
  Future<List<CookingTimer>> read(
    String accountId,
    String recipeSessionId,
  ) async {
    final raw = (await _preferences()).getString(
      _key(accountId, recipeSessionId),
    );
    if (raw == null) return [];
    try {
      final document = jsonDecode(raw);
      if (document is! Map<String, dynamic> ||
          document.length != 2 ||
          document['schemaVersion'] != 1 ||
          document['timers'] is! List) {
        throw const FormatException();
      }
      final rows = document['timers'] as List<dynamic>;
      if (rows.length > _maximumRecords) throw const FormatException();
      final seen = <String>{};
      return rows
          .map((rawRow) {
            if (rawRow is! Map<String, dynamic> || rawRow.length != 9) {
              throw const FormatException();
            }
            final id = rawRow['id'];
            final storedAccount = rawRow['accountId'];
            final storedSession = rawRow['recipeSessionId'];
            final label = rawRow['label'];
            final deadline = rawRow['deadlineWallMicros'];
            final revision = rawRow['revision'];
            final notified = rawRow['notified'];
            final acknowledged = rawRow['acknowledged'];
            if (rawRow['schemaVersion'] != 1 ||
                id is! String ||
                id.isEmpty ||
                !seen.add(id) ||
                storedAccount != accountId ||
                storedSession != recipeSessionId ||
                label is! String ||
                label.trim().isEmpty ||
                label.length > 100 ||
                deadline is! int ||
                deadline < 0 ||
                revision is! int ||
                revision < 1 ||
                notified is! bool ||
                acknowledged is! bool) {
              throw const FormatException();
            }
            return CookingTimer(
              id: id,
              accountId: accountId,
              recipeSessionId: recipeSessionId,
              label: label,
              deadlineWall: Duration(microseconds: deadline),
              revision: revision,
              notified: notified,
              acknowledged: acknowledged,
            );
          })
          .toList(growable: false);
    } on FormatException {
      throw StateError('invalid_cooking_timer_storage');
    }
  }

  @override
  Future<void> write(
    CookingTimer timer, {
    required int expectedRevision,
  }) async {
    final values = await read(timer.accountId, timer.recipeSessionId);
    final index = values.indexWhere((value) => value.id == timer.id);
    final actual = index < 0 ? 0 : values[index].revision;
    if (actual != expectedRevision || timer.revision != expectedRevision + 1) {
      throw StateError('cooking_timer_revision_conflict');
    }
    final updated = List<CookingTimer>.of(values);
    if (index < 0) {
      if (updated.length >= _maximumRecords) {
        throw StateError('cooking_timer_limit_reached');
      }
      updated.add(timer);
    } else {
      updated[index] = timer;
    }
    final document = jsonEncode({
      'schemaVersion': 1,
      'timers': updated.map(_encode).toList(growable: false),
    });
    if (!await (await _preferences()).setString(
      _key(timer.accountId, timer.recipeSessionId),
      document,
    )) {
      throw StateError('cooking_timer_storage_unavailable');
    }
  }

  static Map<String, Object> _encode(CookingTimer value) => {
    'schemaVersion': 1,
    'id': value.id,
    'accountId': value.accountId,
    'recipeSessionId': value.recipeSessionId,
    'label': value.label,
    'deadlineWallMicros': value.deadlineWall.inMicroseconds,
    'revision': value.revision,
    'notified': value.notified,
    'acknowledged': value.acknowledged,
  };
}
