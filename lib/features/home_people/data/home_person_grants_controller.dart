import 'package:flutter/foundation.dart';
import '../../../core/home_session_controller.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/admin/domain/server_admin_models.dart';
import '../domain/home_person_models.dart';

enum HomePersonGrantOutcome { saved, revoked, conflict, uncertain, failed }
class HomePersonGrantsController extends ChangeNotifier {
  HomePersonGrantsController(this.home,this.target,this.factory,this.clock,this.ownerCurrent,this.owner);
  final HomeSessionController? home;
  final HomePersonRecord target;
  final ServerApiFactory factory;
  final DateTime Function() clock;
  final bool Function() ownerCurrent;
  final Listenable owner;
  bool busy = false;
  int epoch = 0;
  String? failure;
  HomePersonGrantOutcome? outcome;
  List<AdminUser> users = const [];
  HomePersonGrants? snapshot;
  bool get fresh => false;
  bool get canRefresh => false;
  bool get canChange => false;
  void setVisible(bool value) {}
  Future<void> refresh() async {}
  Future<void> setPermission(AdminUser selected,HomePersonPermission permission,{required bool Function() isCurrent}) async {}
}
