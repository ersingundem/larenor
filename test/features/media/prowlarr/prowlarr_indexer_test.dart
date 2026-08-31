import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/media/prowlarr/data/models/prowlarr_indexer.dart';

void main() {
  test('parses indexer fields and keeps the raw JSON', () {
    final json = {
      'id': 3,
      'name': '1337x',
      'enable': true,
      'protocol': 'torrent',
      'priority': 25,
      'appProfileId': 1,
    };
    final indexer = ProwlarrIndexer.fromJson(json);

    expect(indexer.id, 3);
    expect(indexer.name, '1337x');
    expect(indexer.enabled, isTrue);
    expect(indexer.protocol, 'torrent');
    expect(indexer.priority, 25);
    expect(indexer.raw, json);
  });

  test('defaults missing fields safely', () {
    final indexer = ProwlarrIndexer.fromJson({});
    expect(indexer.id, 0);
    expect(indexer.name, 'Unknown');
    expect(indexer.enabled, isFalse);
    expect(indexer.protocol, 'unknown');
    expect(indexer.priority, 0);
  });
}
