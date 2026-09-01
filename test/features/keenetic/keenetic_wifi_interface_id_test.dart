import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_access_point.dart';

void main() {
  group('parseKeeneticWifiInterfaceId', () {
    test('parses radio and access point indices', () {
      final parsed = parseKeeneticWifiInterfaceId('WifiMaster0/AccessPoint0');
      expect(parsed, (0, 0));
    });

    test('parses multi-digit indices', () {
      final parsed = parseKeeneticWifiInterfaceId('WifiMaster1/AccessPoint12');
      expect(parsed, (1, 12));
    });

    test('returns null for an id that does not match the expected shape', () {
      expect(parseKeeneticWifiInterfaceId('GigabitEthernet0'), isNull);
      expect(parseKeeneticWifiInterfaceId(''), isNull);
    });
  });
}
