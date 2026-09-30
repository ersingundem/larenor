import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/shared_expenses/domain/shared_expense_models.dart';

const _coreId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _homeId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _accountId = 'cccccccccccccccccccccccccccccccc';

Map<String, dynamic> _authority(int membersRevision) => {
  'schemaVersion': 1,
  'coreId': _coreId,
  'homeId': _homeId,
  'accountId': _accountId,
  'sessionId': 'dddddddddddddddddddddddddddddddd',
  'membersRevision': membersRevision,
  'canViewAll': true,
};

SharedExpenseAuthority _parse(Map<String, dynamic> value) =>
    SharedExpenseAuthority.fromJson(
      value,
      routeId: 'shared-expenses',
      coreId: _coreId,
      homeId: _homeId,
      accountId: _accountId,
    );

void main() {
  test('53-bit authority survives the web JSON boundary exactly', () {
    const revision = 9007199254740991;
    expect(revision, greaterThan(0x7fffffff));

    final decoded = jsonDecode(jsonEncode(_authority(revision)));
    expect(decoded, isA<Map<String, dynamic>>());
    final current = _parse(decoded as Map<String, dynamic>);
    final expected = _parse(_authority(revision));

    expect(current.membersRevision, revision);
    expect(current, expected);
    expect(current.hashCode, expected.hashCode);
  });

  test('authority rejects a revision above the exact web integer range', () {
    expect(() => _parse(_authority(9007199254740992)), throwsFormatException);
  });
}
