import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/auth/data/ha_connection_config.dart';

void main() {
  test('normalizeBaseUrl adds scheme and strips trailing slash', () {
    expect(
      HaConnectionConfig.normalizeBaseUrl('homeassistant.local:8123/'),
      'http://homeassistant.local:8123',
    );
  });
}
