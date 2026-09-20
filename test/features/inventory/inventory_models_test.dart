import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/inventory/domain/inventory_models.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const core = '11111111111111111111111111111111';
const home = '22222222222222222222222222222222';
const itemId = '33333333333333333333333333333333';
const roomId = '44444444444444444444444444444444';
const deviceId = '55555555555555555555555555555555';
const documentId = '66666666666666666666666666666666';
final context = ServerContext.fromJson({
  'schemaVersion': 1,
  'coreId': core,
  'homeId': home,
});

Map<String, Object?> itemResponse({int revision = 3}) => {
  'item': {
    'schemaVersion': 1,
    'ref': {
      'schemaVersion': 1,
      'coreId': core,
      'homeId': home,
      'kind': 'inventory_item',
      'id': itemId,
    },
    'revision': revision,
    'label': 'Kahve değirmeni',
    'links': {
      'schemaVersion': 1,
      'roomId': roomId,
      'deviceId': deviceId,
      'documentIds': [documentId],
    },
  },
};

Map<String, Object?> grantsResponse({int revision = 3}) => {
  'schemaVersion': 1,
  'itemRevision': revision,
  'grants': [
    {'schemaVersion': 1, 'subjectId': '77777777777777777777777777777777'},
  ],
};

Map<String, Object?> historyResponse({int revision = 3}) => {
  'schemaVersion': 1,
  'verified': true,
  'entries': [
    {
      'schemaVersion': 1,
      'sequence': 1,
      'action': 'create',
      'actorId': '88888888888888888888888888888888',
      'itemRevision': 1,
      'createdAt': 1788609600.0,
    },
    {
      'schemaVersion': 1,
      'sequence': 2,
      'action': 'update',
      'actorId': '88888888888888888888888888888888',
      'itemRevision': revision,
      'createdAt': 1788609660.0,
    },
  ],
};

void main() {
  test('strict QR and closed response models bind exact scope and revision', () {
    final value = 'larenor:inventory:v1:$core:$home:$itemId';
    final qr = InventoryQr.parse(value);
    expect(qr.context, context);
    expect(qr.itemId, itemId);
    expect(qr.canonical, value);
    for (final invalid in ['broken', '$value:extra', value.toUpperCase()]) {
      expect(() => InventoryQr.parse(invalid), throwsA(isA<FormatException>()));
    }

    final item = InventoryItem.fromResponse(itemResponse(), expected: context);
    final grants = InventoryGrants.fromResponse(
      grantsResponse(), expectedItem: item,
    );
    final history = InventoryHistory.fromResponse(
      historyResponse(), expectedItem: item,
    );
    expect(item.links.documentIds, [documentId]);
    expect(grants.subjectIds, ['77777777777777777777777777777777']);
    expect(history.entries.map((entry) => entry.action), ['create', 'update']);

    expect(
      () => InventoryItem.fromResponse(
        {...itemResponse(), 'extra': true}, expected: context,
      ),
      throwsA(isA<LarenorServerException>()),
    );
    expect(
      () => InventoryGrants.fromResponse(
        grantsResponse(revision: 2), expectedItem: item,
      ),
      throwsA(isA<LarenorServerException>()),
    );
    expect(
      () => InventoryHistory.fromResponse(
        historyResponse(revision: 2), expectedItem: item,
      ),
      throwsA(isA<LarenorServerException>()),
    );
  });
}
