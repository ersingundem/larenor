import 'package:flutter/foundation.dart';
import '../../../core/home_session_controller.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/services/domain/server_service_models.dart';
import '../domain/core_ha_models.dart';

class CoreHaController extends ChangeNotifier {
  CoreHaController(this.home, this.target, this.factory, this.clock, this.monotonic, this.current, this.owner, {this.admin = false});
  final HomeSessionController? home;
  final HomeResourceRecord target;
  final ServerApiFactory factory;
  final DateTime Function() clock;
  final Duration Function() monotonic;
  final bool Function() current;
  final Listenable owner;
  final bool admin;
  int epoch = 0;
  bool busy = false, loaded = false, stale = false, uncertain = false, saved = false;
  String? failure;
  HomeResourceRecord? record;
  CoreHaSnapshot? snapshot;
  CoreHaBinding? binding;
  CoreHaPreview? preview;
  List<ServerService> services = const [];
  bool get fresh => false;
  bool get canRefresh => false;
  bool get canPreview => false;
  bool get canConfirm => false;
  void setVisible(bool value) {}
  Future<void> refresh() async {}
  Future<void> prepare(ServerService service, String entityId, {required bool Function() isCurrent}) async {}
  Future<void> confirm(CoreHaPreview value, {required bool Function() isCurrent}) async {}
  Future<void> cancel(CoreHaPreview value, {required bool Function() isCurrent}) async {}
}
