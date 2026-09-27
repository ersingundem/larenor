import '../../data/larenor_server_api.dart';
import '../domain/server_component_update_models.dart';

final class ServerComponentUpdatesApi {
  const ServerComponentUpdatesApi(this.api, this.token);

  final LarenorServerApi api;
  final String token;

  Future<ServerComponentUpdateInventory> inventory() async =>
      ServerComponentUpdateInventory.fromJson(
        await api.request('GET', '/admin/component-updates', token: token),
      );
}
