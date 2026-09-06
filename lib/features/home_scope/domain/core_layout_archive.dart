import '../../../core/home_data_scope.dart';

const maxCoreLayoutArchiveBytes = 2 * 1024 * 1024;

final class CoreLayoutArchiveException implements Exception {
  const CoreLayoutArchiveException(this.code);
  final String code;
  @override
  String toString() => 'CoreLayoutArchiveException($code)';
}

final class CoreLayoutArchiveRoom {
  const CoreLayoutArchiveRoom._(this.id, this.name);
  final String id;
  final String name;
}

final class CoreLayoutArchiveV1 {
  CoreLayoutArchiveV1._();
  factory CoreLayoutArchiveV1.fromJson(Object? value) =>
      throw const CoreLayoutArchiveException('invalid_archive');
  factory CoreLayoutArchiveV1.decode(String value) =>
      throw const CoreLayoutArchiveException('invalid_archive');
  factory CoreLayoutArchiveV1.fromScopedLayout({
    required HomeDataScope scope,
    required int sourceRevision,
    required DateTime capturedAt,
    required Object? layout,
  }) => throw const CoreLayoutArchiveException('unsupported_layout');

  DateTime get capturedAt => throw UnimplementedError();
  int get sourceRevision => throw UnimplementedError();
  String get scopeDigest => throw UnimplementedError();
  List<CoreLayoutArchiveRoom> get rooms => throw UnimplementedError();
  bool matchesScope(HomeDataScope scope) => false;
  Map<String, dynamic> toJson() => throw UnimplementedError();
  String encode() => throw UnimplementedError();
}
