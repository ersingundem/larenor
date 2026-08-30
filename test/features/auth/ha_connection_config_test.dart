import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/auth/data/ha_connection_config.dart';

void main() {
  group('HaConnectionConfig.normalizeBaseUrl', () {
    test('adds http scheme when missing', () {
      expect(
        HaConnectionConfig.normalizeBaseUrl('homeassistant.local:8123'),
        'http://homeassistant.local:8123',
      );
    });

    test('preserves an explicit https scheme', () {
      expect(
        HaConnectionConfig.normalizeBaseUrl('https://ha.example.com'),
        'https://ha.example.com',
      );
    });

    test('strips a single trailing slash', () {
      expect(
        HaConnectionConfig.normalizeBaseUrl('http://homeassistant.local:8123/'),
        'http://homeassistant.local:8123',
      );
    });

    test('strips multiple trailing slashes', () {
      expect(
        HaConnectionConfig.normalizeBaseUrl(
          'http://homeassistant.local:8123///',
        ),
        'http://homeassistant.local:8123',
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        HaConnectionConfig.normalizeBaseUrl(
          '  http://homeassistant.local:8123  ',
        ),
        'http://homeassistant.local:8123',
      );
    });
  });
}
