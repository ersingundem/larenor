import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../server/data/larenor_server_api.dart';
import '../../server/data/server_account_controller.dart';
import '../domain/home_person_models.dart';
import 'home_people_controller.dart';
import 'home_person_grants_controller.dart';

class HomePeopleOwner extends ChangeNotifier {
  HomePeopleOwner({required bool Function() isCurrent,required AppInteractionController interaction});
  bool get isCurrent => true;
  void synchronize() {}
  void retire() {}
}
final homePeopleApiFactoryProvider = Provider<ServerApiFactory>((_) => (endpoint) => LarenorServerApi(endpoint:endpoint));
final homePeopleClockProvider = Provider<DateTime Function()>((_) => DateTime.now);
typedef HomePeopleSelection = ({HomePeopleOwner owner, bool adminManagement, int pageSize});
final homePeopleControllerProvider = Provider.autoDispose.family<HomePeopleController, HomePeopleSelection>((ref,selection) {
  final controller = HomePeopleController(ref.watch(homeSessionControllerProvider),ref.watch(homePeopleApiFactoryProvider),ref.watch(homePeopleClockProvider),() => selection.owner.isCurrent,selection.owner,adminManagement:selection.adminManagement,pageSize:selection.pageSize);
  ref.onDispose(controller.dispose);
  return controller;
});
typedef HomePersonGrantSelection = ({HomePeopleOwner owner, HomePersonRecord target});
final homePersonGrantsControllerProvider = Provider.autoDispose.family<HomePersonGrantsController,HomePersonGrantSelection>((ref,selection) {
  final controller = HomePersonGrantsController(ref.watch(homeSessionControllerProvider),selection.target,ref.watch(homePeopleApiFactoryProvider),ref.watch(homePeopleClockProvider),() => selection.owner.isCurrent,selection.owner);
  ref.onDispose(controller.dispose);
  return controller;
});
