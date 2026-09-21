import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/shared_expenses/domain/shared_expense_models.dart';

void main() {
  Map<String, dynamic> record() => {
    'id': '1' * 32,
    'revision': 1,
    'title': 'Internet',
    'currency': 'TRY',
    'currencyScale': 2,
    'totalMinor': 1001,
    'payerId': 'a' * 32,
    'shares': [
      {'accountId': 'a' * 32, 'amountMinor': 501},
      {'accountId': 'b' * 32, 'amountMinor': 500},
    ],
    'createdAt': 1789980000.25,
  };

  test(
    'accepts the exact Core export record and preserves every minor unit',
    () {
      final value = SharedExpenseRecord.fromJson(record());
      expect(value.id, '1' * 32);
      expect(value.shares.map((share) => share.amountMinor), [501, 500]);
    },
  );

  test('rejects unknown fields, invalid timestamps, and inexact shares', () {
    final unknown = record()..['private'] = 'leak';
    expect(() => SharedExpenseRecord.fromJson(unknown), throwsFormatException);
    final invalidTime = record()..['createdAt'] = -1;
    expect(
      () => SharedExpenseRecord.fromJson(invalidTime),
      throwsFormatException,
    );
    final inexact = record();
    (inexact['shares'] as List).first['amountMinor'] = 500;
    expect(() => SharedExpenseRecord.fromJson(inexact), throwsFormatException);
  });
}
