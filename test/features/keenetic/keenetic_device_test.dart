import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/keenetic/data/models/keenetic_device.dart';

void main() {
  test('parses name, falling back to hostname then mac', () {
    final named = KeeneticDevice.fromJson({
      'mac': 'AA:BB:CC',
      'name': 'My Phone',
      'ip': '192.168.1.50',
      'active': true,
    });
    expect(named.name, 'My Phone');
    expect(named.ip, '192.168.1.50');
    expect(named.active, isTrue);

    final hostnameOnly = KeeneticDevice.fromJson({
      'mac': 'AA:BB:CC',
      'hostname': 'my-phone',
    });
    expect(hostnameOnly.name, 'my-phone');

    final macOnly = KeeneticDevice.fromJson({'mac': 'AA:BB:CC'});
    expect(macOnly.name, 'AA:BB:CC');
    expect(macOnly.active, isFalse);
  });

  test('ignores empty names and accepts router flag encodings', () {
    final device = KeeneticDevice.fromJson({
      'name': '',
      'hostname': 'Tablet',
      'active': 'yes',
      'registered': true,
      'via': 'WifiMaster0/AccessPoint0',
    });
    expect(device.name, 'Tablet');
    expect(device.active, isTrue);
    expect(device.registered, isTrue);
    expect(device.interfaceId, 'WifiMaster0/AccessPoint0');
  });
}
