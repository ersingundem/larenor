import '../../server/data/larenor_server_api.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_person_models.dart';

final class HomePeopleApi {
  HomePeopleApi(LarenorServerApi api,String token,ServerContext context,{required bool Function() isCurrent});
  void retire() {}
  Future<HomePeoplePage> list({String? after,String? snapshot,int limit=25}) async => throw const LarenorServerException('invalid_response');
  Future<HomePersonRecord> get(String id) async => throw const LarenorServerException('invalid_response');
  Future<HomePersonRecord> create({required String label,required int order}) async => throw const LarenorServerException('invalid_response');
  Future<HomePersonRecord> update(HomePersonRecord target,{required String label,required int order}) async => throw const LarenorServerException('invalid_response');
  Future<void> delete(HomePersonRecord target) async => throw const LarenorServerException('invalid_response');
  Future<HomePersonGrants> grants(HomePersonRecord target) async => throw const LarenorServerException('invalid_response');
  Future<HomePersonGrants> setGrant(HomePersonGrants snapshot,{required String subjectId,required HomePersonPermission permission}) async => throw const LarenorServerException('invalid_response');
}
