import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/inventory/domain/inventory_models.dart';
import 'package:larenor/features/inventory/domain/inventory_qr_export.dart';

import 'inventory_models_test.dart';

void main() {
  test(
    'QR render/export is canonical bounded and contains no attached secrets',
    () {
      final qr = InventoryQr.parse('larenor:inventory:v1:$core:$home:$itemId');
      final export = InventoryQrExport.fromQr(qr);

      expect(export.payload, qr.canonical);
      expect(export.fileName, 'larenor-inventory-$itemId.svg');
      expect(export.mimeType, 'image/svg+xml');
      expect(export.moduleCount, inInclusiveRange(21, 177));
      expect(export.svg.length, lessThanOrEqualTo(256000));
      expect(export.svg, contains('<svg'));
      expect(export.svg, isNot(contains('token')));
      expect(export.svg, isNot(contains('Kahve değirmeni')));
      expect(export.svg, isNot(contains(roomId)));
      expect(export.toString(), 'InventoryQrExport');
    },
  );
}
