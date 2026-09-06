import '../../server/domain/server_models.dart';

/// Immutable request metadata; this value carries no authorization.
final class HomeResourceMetadata {
  factory HomeResourceMetadata({required String label, required int order}) {
    final runes = label.runes;
    if (runes.isEmpty ||
        runes.length > 80 ||
        order < 0 ||
        order > 10000 ||
        runes.any(
          (rune) =>
              rune < 32 || rune == 127 || rune >= 0xd800 && rune <= 0xdfff,
        )) {
      throw const LarenorServerException('invalid_request');
    }
    // Same Python str.strip edges as the existing read model. BOM is content.
    final canonical = label.replaceAll(_edgeWhitespace, '');
    if (canonical.isEmpty) {
      throw const LarenorServerException('invalid_request');
    }
    return HomeResourceMetadata._(canonical, order);
  }
  const HomeResourceMetadata._(this.label, this.order);
  final String label;
  final int order;
  Map<String, dynamic> toJson() => {'label': label, 'order': order};
  @override
  String toString() => 'HomeResourceMetadata';
}

final _edgeWhitespace = RegExp(
  r'^[\x09-\x0d\x1c-\x20\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+|[\x09-\x0d\x1c-\x20\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+$',
);
