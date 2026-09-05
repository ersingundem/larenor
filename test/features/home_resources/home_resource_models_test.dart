import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

Map<String, Object?> scope() => {
  'schemaVersion': 1,
  'coreId': 'a' * 32,
  'homeId': 'b' * 32,
};
Map<String, Object?> record([String id = '1']) => {
  'ref': {...scope(), 'kind': 'room', 'id': id * 32},
  'label': 'Kitchen',
  'order': 2,
  'revision': 1,
  'aclRevision': 1,
  'permissions': <String, Object?>{'read': true, 'write': false},
};
Map<String, Object?> page() => {
  'scope': scope(),
  'entries': [record()],
  'snapshot': 'a' * 64,
  'nextAfter': null,
};
Matcher get invalid => throwsA(
  isA<LarenorServerException>().having(
    (e) => e.code,
    'code',
    'invalid_response',
  ),
);

void main() {
  test('immutable exact public metadata page binds each resource to requested home', () {
    final raw = page();
    final value = HomeResourcePage.fromJson(
      raw,
      expectedContext: ServerContext.fromJson(scope()),
    );
    expect(value.entries.single.label, 'Kitchen');
    expect(value.entries.single.kind, HomeResourceKind.room);
    expect(value.entries.single.canWrite, isFalse);
    expect(value.snapshot, 'a' * 64);
    expect(value.nextAfter, isNull);
    (raw['entries'] as List).clear();
    expect(value.entries, hasLength(1));
    expect(() => value.entries.clear(), throwsUnsupportedError);
    expect(value.toString(), 'HomeResourcePage');
  });
  final changes = <String, void Function(Map<String, Object?>)>{
    'unknown envelope': (p) => p['private'] = 'synthetic-secret',
    'missing snapshot': (p) => p.remove('snapshot'),
    'float schema': (p) => (p['scope'] as Map)['schemaVersion'] = 1.0,
    'boolean schema': (p) => (p['scope'] as Map)['schemaVersion'] = true,
    'wrong home': (p) => (p['scope'] as Map)['homeId'] = 'c' * 32,
    'uppercase snapshot': (p) => p['snapshot'] = 'A' * 64,
    'short snapshot': (p) => p['snapshot'] = 'a' * 63,
    'oversize page': (p) => p['entries'] = List.generate(26, (_) => record()),
    'duplicate id': (p) => p['entries'] = [record(), record()],
    'unsorted ids': (p) => p['entries'] = [record('2'), record('1')],
    'wrong resource scope': (p) =>
        (((p['entries'] as List).first as Map)['ref'] as Map)['coreId'] =
            'c' * 32,
    'unknown kind': (p) =>
        (((p['entries'] as List).first as Map)['ref'] as Map)['kind'] = 'vault',
    'unknown ref key': (p) =>
        (((p['entries'] as List).first as Map)['ref'] as Map)['url'] =
            'https://private.invalid',
    'unreadable record': (p) =>
        (((p['entries'] as List).first as Map)['permissions'] as Map)['read'] =
            false,
    'nonbool write': (p) =>
        (((p['entries'] as List).first as Map)['permissions'] as Map)['write'] =
            1,
    'extra permission': (p) =>
        (((p['entries'] as List).first as Map)['permissions'] as Map)['admin'] =
            true,
    'unknown record key': (p) =>
        ((p['entries'] as List).first as Map)['token'] = 'synthetic-secret',
    'zero revision': (p) =>
        ((p['entries'] as List).first as Map)['revision'] = 0,
    'float acl revision': (p) =>
        ((p['entries'] as List).first as Map)['aclRevision'] = 1.0,
    'oversize revision': (p) =>
        ((p['entries'] as List).first as Map)['revision'] =
            '9223372036854775808',
    'negative order': (p) =>
        ((p['entries'] as List).first as Map)['order'] = -1,
    'oversize order': (p) =>
        ((p['entries'] as List).first as Map)['order'] = 10001,
    'empty label': (p) => ((p['entries'] as List).first as Map)['label'] = '',
    'blank label': (p) => ((p['entries'] as List).first as Map)['label'] = '  ',
    'oversize label': (p) =>
        ((p['entries'] as List).first as Map)['label'] = 'a' * 81,
    'control label': (p) =>
        ((p['entries'] as List).first as Map)['label'] = 'a\nb',
    'surrogate label': (p) =>
        ((p['entries'] as List).first as Map)['label'] = '\uD800',
    'cursor different from last': (p) => p['nextAfter'] = '2' * 32,
    'empty continuation': (p) {
      p['entries'] = [];
      p['nextAfter'] = '1' * 32;
    },
  };
  for (final change in changes.entries) {
    test('rejects ${change.key} with static typed failure', () {
      final raw = page();
      change.value(raw);
      expect(
        () => HomeResourcePage.fromJson(
          raw,
          expectedContext: ServerContext.fromJson(scope()),
        ),
        invalid,
      );
    });
  }
  test('Unicode labels count code points, with strict integer boundaries', () {
    final raw = page();
    final entry = (raw['entries'] as List).single as Map;
    entry['label'] = '😀' * 80;
    entry['revision'] = 9223372036854775807;
    entry['aclRevision'] = 9223372036854775807;
    final value = HomeResourcePage.fromJson(
      raw,
      expectedContext: ServerContext.fromJson(scope()),
    );
    expect(value.entries.single.label.runes.length, 80);
  });
  test(
    'continuation binds opaque snapshot and advances beyond requested ID',
    () {
      final raw = page();
      raw['entries'] = [record('2')];
      raw['nextAfter'] = '2' * 32;
      final context = ServerContext.fromJson(scope());
      expect(
        HomeResourcePage.fromJson(
          raw,
          expectedContext: context,
          after: '1' * 32,
          expectedSnapshot: 'a' * 64,
        ).nextAfter,
        '2' * 32,
      );
      expect(
        () => HomeResourcePage.fromJson(
          raw,
          expectedContext: context,
          after: '2' * 32,
          expectedSnapshot: 'a' * 64,
        ),
        invalid,
      );
      expect(
        () => HomeResourcePage.fromJson(
          raw,
          expectedContext: context,
          after: '1' * 32,
          expectedSnapshot: 'b' * 64,
        ),
        invalid,
      );
    },
  );
}
