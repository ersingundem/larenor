import '../../server/domain/server_models.dart';

Never _missing() => throw const LarenorServerException('invalid_response');

final class HomePersonRecord {
  factory HomePersonRecord.fromJson(Object? raw, {required ServerContext expectedContext}) => _missing();
  ServerContext get context => _missing();
  String get id => _missing();
  String get label => _missing();
  int get order => _missing();
  int get revision => _missing();
  int get aclRevision => _missing();
  bool get canWrite => _missing();
}

final class HomePersonMetadata {
  factory HomePersonMetadata({required String label, required int order}) => throw const LarenorServerException('invalid_request');
  String get label => _missing();
  Map<String,dynamic> toJson() => _missing();
}

final class HomePeoplePage {
  factory HomePeoplePage.fromJson(Object? raw, {required ServerContext expectedContext, String? after, String? expectedSnapshot, int limit=25}) => _missing();
  static const maximumRecords=128;
  List<HomePersonRecord> get entries => _missing();
  String get snapshot => _missing();
  String? get nextAfter => _missing();
}

enum HomePersonPermission {none, readOnly, readWrite}

final class HomePersonGrants {
  factory HomePersonGrants.fromJson(Object? raw, {required HomePersonRecord target}) => _missing();
  HomePersonPermission permissionFor(String subject) => _missing();
  HomePersonGrants withUpdatedGrant(Object? raw, {required String subjectId, required HomePersonPermission permission}) => _missing();
  int get aclRevision => _missing();
  Map<String,HomePersonPermission> get grants => _missing();
}
