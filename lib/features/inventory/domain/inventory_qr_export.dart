import 'package:qr/qr.dart';

import 'inventory_models.dart';

/// A deterministic, secret-free artifact derived only from the canonical
/// scoped inventory identifier. Labels, grants and document references are
/// never accepted by this type and therefore cannot leak into exports.
final class InventoryQrExport {
  InventoryQrExport._({
    required this.payload,
    required this.fileName,
    required this.moduleCount,
    required this.svg,
  });

  factory InventoryQrExport.fromQr(InventoryQr qr) {
    final image = QrImage(
      QrCode(
        payload: QrPayload.fromString(qr.canonical),
        errorCorrectLevel: QrErrorCorrectLevel.medium,
      ),
    );
    const quiet = 4;
    final extent = image.moduleCount + quiet * 2;
    final svg = StringBuffer()
      ..write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ')
      ..write(extent)
      ..write(' ')
      ..write(extent)
      ..write('" shape-rendering="crispEdges"><path fill="#fff" d="M0 0h')
      ..write(extent)
      ..write('v')
      ..write(extent)
      ..write('H0z"/><path fill="#000" d="');
    for (var row = 0; row < image.moduleCount; row++) {
      for (var column = 0; column < image.moduleCount; column++) {
        if (image.isDark(row, column)) {
          svg
            ..write('M')
            ..write(column + quiet)
            ..write(' ')
            ..write(row + quiet)
            ..write('h1v1h-1z');
        }
      }
    }
    svg.write('"/></svg>');
    if (svg.length > 256000) {
      throw const FormatException('Inventory QR export is too large.');
    }
    return InventoryQrExport._(
      payload: qr.canonical,
      fileName: 'larenor-inventory-${qr.itemId}.svg',
      moduleCount: image.moduleCount,
      svg: svg.toString(),
    );
  }

  String get mimeType => 'image/svg+xml';
  final String payload, fileName, svg;
  final int moduleCount;

  @override
  String toString() => 'InventoryQrExport';
}
