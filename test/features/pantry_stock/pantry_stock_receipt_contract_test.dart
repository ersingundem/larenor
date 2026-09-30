import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/pantry_stock/domain/pantry_stock_models.dart';
import 'package:larenor/features/server/domain/server_models.dart';

void main() {
  final context = ServerContext.fromJson({
    'schemaVersion': 1,
    'coreId': 'a' * 32,
    'homeId': 'b' * 32,
  });
  final response = {
    'scope': context.toJson(),
    'receipt': {
      'schemaVersion': 1,
      'requestId': '1' * 32,
      'movementId': '2' * 32,
      'revision': 1,
      'kind': 'receive',
      'allocations': [
        {'schemaVersion': 1, 'lotId': '3' * 32, 'quantity': 1000},
      ],
    },
    'snapshot': {
      'schemaVersion': 1,
      'revision': 4,
      'lots': [
        {
          'schemaVersion': 1,
          'lotId': '3' * 32,
          'ingredientKey': 'flour',
          'measure': 'mass_mg',
          'remaining': 1000,
          'expiresOn': null,
        },
      ],
    },
  };
  PantryMutation parse(Object raw) => PantryMutation.fromResponse(
    raw,
    expected: context,
    expectedRequestId: '1' * 32,
    expectedKind: 'receive',
  );

  test('old receipt preserves a newer authoritative stock snapshot', () {
    final value = parse(response);
    expect(value.receipt.revision, 1);
    expect(value.snapshot.revision, 4);
    expect(value.snapshot.lots.single.remaining, 1000);
  });

  for (final entry in <String, Object>{
    'revision': 5,
    'requestId': '4' * 32,
    'kind': 'consume',
  }.entries) {
    test('rejects mismatched receipt ${entry.key}', () {
      final value = jsonDecode(jsonEncode(response)) as Map<String, dynamic>;
      (value['receipt'] as Map<String, dynamic>)[entry.key] = entry.value;
      expect(() => parse(value), throwsFormatException);
    });
  }
}
