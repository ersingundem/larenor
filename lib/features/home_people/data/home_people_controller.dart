import 'package:flutter/foundation.dart';
import '../../../core/home_session_controller.dart';
import '../../server/data/server_account_controller.dart';
import '../domain/home_person_models.dart';

enum HomePersonMutationOutcome { saved, deleted, conflict, uncertain, failed }
class HomePeopleController extends ChangeNotifier {
  HomePeopleController(this.home, this.factory, this.clock, this.ownerCurrent, this.owner, {this.adminManagement = false, this.pageSize = 25});
  final HomeSessionController? home;
  final ServerApiFactory factory;
  final DateTime Function() clock;
  final bool Function() ownerCurrent;
  final Listenable owner;
  final bool adminManagement;
  final int pageSize;
  bool busy = false, loaded = false;
  int epoch = 0;
  String? failure, nextAfter, snapshot;
  HomePersonMutationOutcome? mutationOutcome;
  List<HomePersonRecord> entries = const [];
  bool get fresh => false;
  bool get canRefresh => false;
  bool get canLoadMore => false;
  bool get canManage => false;
  bool get canMutate => false;
  void setVisible(bool value) {}
  Future<void> refresh() async {}
  Future<void> loadMore() async {}
  Future<void> create({required String label,required int order,required bool Function() isCurrent}) async {}
  Future<void> update(HomePersonRecord target,{required String label,required int order,required bool Function() isCurrent}) async {}
  Future<void> delete(HomePersonRecord target,{required bool Function() isCurrent}) async {}
}
