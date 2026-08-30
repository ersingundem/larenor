import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/dashboard_layout.dart';

/// Persists the dashboard tile layout locally as a JSON blob.
///
/// MVP-scale persistence; revisit (e.g. drift/isar, multi-dashboard support)
/// once layouts grow beyond a single simple grid.
class DashboardRepository {
  static const _key = 'dashboard_layout';

  Future<DashboardLayout> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const DashboardLayout();
    return DashboardLayout.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(DashboardLayout layout) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(layout.toJson()));
  }
}
