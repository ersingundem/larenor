import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/keenetic/data/models/keenetic_access_point.dart';

void main() {
  test('name prefers description, then ssid, then id', () {
    final withDescription = KeeneticAccessPoint.fromJson({
      'id': 'WifiMaster0/AccessPoint0',
      'description': 'Home Wi-Fi',
      'ssid': 'MyNetwork',
      'state': 'up',
    });
    expect(withDescription.name, 'Home Wi-Fi');
    expect(withDescription.up, isTrue);

    final ssidOnly = KeeneticAccessPoint.fromJson({
      'id': 'WifiMaster0/AccessPoint1',
      'ssid': 'Guest',
      'link': 'down',
    });
    expect(ssidOnly.name, 'Guest');
    expect(ssidOnly.up, isFalse);
  });

  test('up is true when connected flag is set even without state/link', () {
    final ap = KeeneticAccessPoint.fromJson({
      'id': 'WifiMaster0/AccessPoint0',
      'connected': true,
    });
    expect(ap.up, isTrue);
  });
}
