import '../../server/domain/server_models.dart';

/// Immutable request metadata; this value carries no authorization.
final class HomeResourceMetadata {
  factory HomeResourceMetadata({required String label, required int order}) =>
      throw const LarenorServerException('invalid_request');
  const HomeResourceMetadata._(this.label, this.order);
  final String label;
  final int order;
  Map<String, dynamic> toJson() => {'label': label, 'order': order};
  @override
  String toString() => 'HomeResourceMetadata';
}
