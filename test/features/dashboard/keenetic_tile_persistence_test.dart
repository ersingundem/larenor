import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:larenor/features/backup/data/backup_snapshot.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout_validation.dart';
import 'package:larenor/features/keenetic/domain/keenetic_metric.dart';

Map<String, dynamic> tile([Map<String, dynamic> fields = const {}]) => {
  'id': 'metric',
  'type': 'keenetic',
  'x': 0,
  'y': 0,
  'width': 2,
  'height': 2,
  ...fields,
};
Map<String, dynamic> layout(Map<String, dynamic> value) => {
  'schemaVersion': 2,
  'rooms': [],
  'tiles': [value],
};
Map<String, dynamic> backup(Map<String, dynamic> value) => {
  'version': 1,
  'createdAt': '2026-09-05T00:00:00Z',
  'groups': {'dashboard': value},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final kind in [null, ...KeeneticMetricKind.values]) {
    test(
      'legacy or ${kind?.name} survives persistence and portable backup',
      () async {
        final raw = layout(
          tile({
            if (kind != null) 'keeneticMetric': kind.name,
            if (kind == KeeneticMetricKind.wanTraffic)
              'keeneticInterfaceId': 'GigabitEthernet0/Vlan2',
          }),
        );
        validateDashboardLayoutJson(raw);
        final value = DashboardLayout.fromJson(raw);
        await DashboardRepository().save(value);
        expect(await DashboardRepository().load(), value);
        final decoded =
            jsonDecode(jsonEncode(value.toJson())) as Map<String, dynamic>;
        expect(DashboardLayout.fromJson(decoded), value);
        expect(BackupSnapshot.fromJson(backup(decoded)).hasDashboard, isTrue);
      },
    );
  }

  final invalid = <String, Map<String, dynamic>>{
    'unknown metric': {'keeneticMetric': 'executeCommand'},
    'interface without metric': {'keeneticInterfaceId': 'ISP'},
    'traffic without interface': {'keeneticMetric': 'wanTraffic'},
    'empty interface': {
      'keeneticMetric': 'wanTraffic',
      'keeneticInterfaceId': '',
    },
    'control byte': {
      'keeneticMetric': 'wanTraffic',
      'keeneticInterfaceId': 'ISP\n',
    },
    'oversized selector': {
      'keeneticMetric': 'wanTraffic',
      'keeneticInterfaceId': 'x' * 257,
    },
    'unexpected selector': {
      'keeneticMetric': 'internetStatus',
      'keeneticInterfaceId': 'ISP',
    },
    'wrong tile': {'type': 'entity', 'keeneticMetric': 'internetStatus'},
    'entity injection': {
      'entityId': 'button.unlock',
      'keeneticMetric': 'internetStatus',
    },
    'URL injection': {
      'url': 'http://router.test/command',
      'keeneticMetric': 'internetStatus',
    },
  };
  for (final entry in invalid.entries) {
    test('local and portable validators reject ${entry.key}', () {
      final raw = layout(tile(entry.value));
      expect(() => validateDashboardLayoutJson(raw), throwsFormatException);
      expect(
        () => BackupSnapshot.fromJson(backup(raw)),
        throwsA(isA<BackupValidationException>()),
      );
    });
  }
}
