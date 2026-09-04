import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/keenetic/data/keenetic_config.dart';

void main() {
  test('normalizes whitespace and trailing slashes while preserving a proxy prefix', () {
    expect(
      KeeneticConfig.normalizeBaseUrl(' https://router.example/keenetic/// '),
      'https://router.example/keenetic',
    );
  });

  test('rejects malformed addresses, secrets, queries and fragments', () {
    for (final value in [
      '192.168.1.1',
      'file:///tmp/router',
      'https://admin:secret@router',
      'http://router?token=secret',
      'http://router/#page',
      'http://my router',
      'http://',
    ]) {
      expect(
        () => KeeneticConfig.normalizeBaseUrl(value),
        throwsFormatException,
        reason: value,
      );
    }
  });
}
