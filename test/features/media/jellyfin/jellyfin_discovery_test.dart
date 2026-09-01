import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_discovery.dart';

void main() {
  group('parseJellyfinDiscoveryResponse', () {
    test('parses a well-formed discovery reply', () {
      final data = utf8.encode(
        jsonEncode({
          'Address': 'http://192.168.1.50:8096',
          'Id': 'abc123',
          'Name': 'Living Room Jellyfin',
        }),
      );

      final parsed = parseJellyfinDiscoveryResponse(data);

      expect(parsed, isNotNull);
      expect(parsed!.id, 'abc123');
      expect(parsed.server.baseUrl, 'http://192.168.1.50:8096');
      expect(parsed.server.name, 'Living Room Jellyfin');
    });

    test('falls back to the address as the name when Name is missing', () {
      final data = utf8.encode(
        jsonEncode({'Address': 'http://192.168.1.50:8096', 'Id': 'abc123'}),
      );

      final parsed = parseJellyfinDiscoveryResponse(data);

      expect(parsed!.server.name, 'http://192.168.1.50:8096');
    });

    test('returns null when Address is missing', () {
      final data = utf8.encode(jsonEncode({'Id': 'abc123', 'Name': 'X'}));
      expect(parseJellyfinDiscoveryResponse(data), isNull);
    });

    test('returns null when Id is missing', () {
      final data = utf8.encode(
        jsonEncode({'Address': 'http://192.168.1.50:8096', 'Name': 'X'}),
      );
      expect(parseJellyfinDiscoveryResponse(data), isNull);
    });

    test('returns null for malformed JSON instead of throwing', () {
      expect(parseJellyfinDiscoveryResponse(utf8.encode('not json')), isNull);
    });

    test('returns null for non-JSON binary garbage', () {
      expect(parseJellyfinDiscoveryResponse([0xff, 0xfe, 0x00, 0x01]), isNull);
    });
  });
}
