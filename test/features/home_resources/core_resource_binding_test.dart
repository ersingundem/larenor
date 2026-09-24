import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/home_resources/domain/core_resource_binding.dart';
import 'package:larenor/features/home_resources/domain/home_resource_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  final context = ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
  });
  final record = HomeResourceRecord.fromJson({
    'ref': {
      'schemaVersion': 1,
      'coreId': 'a' * 32,
      'homeId': 'b' * 32,
      'kind': 'resource',
      'id': 'c' * 32,
    },
    'label': 'Router',
    'order': 1,
    'revision': 2,
    'aclRevision': 3,
    'permissions': {'read': true, 'write': false},
  }, expectedContext: context);

  test('strict versioned binding matches every current authority revision', () {
    final binding = CoreResourceBinding.fromRecord(record, userRevision: 4);
    expect(CoreResourceBinding.fromJson(binding.toJson()), binding);
    expect(binding.matches(record, 4), isTrue);
    expect(binding.matches(record, 5), isFalse);
    final changed = HomeResourceRecord.fromJson({
      ...{
        'ref': {
          'schemaVersion': 1,
          'coreId': 'a' * 32,
          'homeId': 'b' * 32,
          'kind': 'resource',
          'id': 'c' * 32,
        },
        'label': 'Router',
        'order': 1,
        'revision': 2,
        'aclRevision': 4,
        'permissions': {'read': true, 'write': false},
      },
    }, expectedContext: context);
    expect(binding.matches(changed, 4), isFalse);
  });

  test('unknown fields kinds versions and unbounded revisions fail closed', () {
    final valid = CoreResourceBinding.fromRecord(
      record,
      userRevision: 4,
    ).toJson();
    for (final invalid in [
      {...valid, 'extra': true},
      {...valid, 'schemaVersion': 2},
      {...valid, 'kind': 'vault'},
      {...valid, 'aclRevision': 0},
      {...valid, 'resourceId': 'not-an-id'},
    ]) {
      expect(
        () => CoreResourceBinding.fromJson(invalid),
        throwsFormatException,
      );
    }
  });
}
