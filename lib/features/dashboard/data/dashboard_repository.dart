import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/configuration_writes.dart';
import '../domain/dashboard_layout.dart';
import '../domain/dashboard_layout_validation.dart';

class DashboardRepository {
  static const _key = 'dashboard_layout';

  Future<DashboardLayout> load() => ConfigurationWrites.run(() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const DashboardLayout();
    if (utf8.encode(raw).length > maxDashboardLayoutBytes) {
      throw const FormatException('Invalid dashboard layout');
    }
    try {
      final value = jsonDecode(raw);
      validateDashboardLayoutJson(value);
      return DashboardLayout.fromJson(value as Map<String, dynamic>);
    } catch (_) {
      // Malformed data is never replaced by an empty persisted dashboard.
      throw const FormatException('Invalid dashboard layout');
    }
  });

  Future<void> save(DashboardLayout layout, {bool Function()? isCurrent}) {
    // Freeze and validate before entering the async queue.
    final encoded = jsonEncode(layout.toJson());
    validateDashboardLayoutJson(jsonDecode(encoded));
    return ConfigurationWrites.run(() async {
      if (isCurrent?.call() == false) {
        throw StateError('Dashboard edit expired');
      }
      final prefs = await SharedPreferences.getInstance();
      if (isCurrent?.call() == false) {
        throw StateError('Dashboard edit expired');
      }
      if (!await prefs.setString(_key, encoded)) {
        throw StateError('Dashboard save failed');
      }
    });
  }
}
