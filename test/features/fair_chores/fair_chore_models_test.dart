import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/fair_chores/domain/fair_chore_models.dart';

const coreId = '11111111111111111111111111111111';
const homeId = '22222222222222222222222222222222';
const accountId = '33333333333333333333333333333333';
const sessionId = '44444444444444444444444444444444';

Map<String, dynamic> authority({int revision = 7}) => {
  'schemaVersion': 1,
  'coreId': coreId,
  'homeId': homeId,
  'accountId': accountId,
  'sessionId': sessionId,
  'membersRevision': revision,
};

void main() {
  test('authority binds exact Core home account session route and members', () {
    final first = FairChoreAuthority.fromJson(
      authority(),
      routeId: 'route-a',
      coreId: coreId,
      homeId: homeId,
      accountId: accountId,
    );
    final changed = FairChoreAuthority.fromJson(
      authority(revision: 8),
      routeId: 'route-a',
      coreId: coreId,
      homeId: homeId,
      accountId: accountId,
    );
    expect(first.sessionId, sessionId);
    expect(first.membersRevision, 7);
    expect(changed, isNot(first));
    expect(
      () => FairChoreAuthority.fromJson(
        {...authority(), 'homeId': 'ffffffffffffffffffffffffffffffff'},
        routeId: 'route-a',
        coreId: coreId,
        homeId: homeId,
        accountId: accountId,
      ),
      throwsFormatException,
    );
  });

  test('task parser rejects extra fields and malformed identities', () {
    final value = {
      'id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'title': 'Water plants',
      'revision': 2,
      'assigneeId': accountId,
      'assigneeLabel': 'Ada',
      'dueAt': 1788609600.0,
    };
    final task = FairChoreTask.fromJson(value);
    expect(task.assigneeLabel, 'Ada');
    expect(task.dueAt.isUtc, isTrue);
    expect(
      () => FairChoreTask.fromJson({...value, 'secret': 'must fail'}),
      throwsFormatException,
    );
  });
}
