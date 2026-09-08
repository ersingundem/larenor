import 'package:flutter/foundation.dart';
import '../../../core/home_session_controller.dart';
import '../../auth/data/credentials_store.dart';
import '../../dashboard/data/dashboard_repository.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/data/server_account_controller.dart';
import 'transfer_models.dart';

class CoreHaTransferController extends ChangeNotifier {
  CoreHaTransferController({required this.home, required this.repository, required this.credentials,
    required this.factory, required this.clock, required this.monotonic, required this.requestId,
    required this.current, required this.owner});
  final HomeSessionController? home;
  final DashboardRepository repository;
  final CredentialsStore credentials;
  final ServerApiFactory factory;
  final DateTime Function() clock;
  final Duration Function() monotonic;
  final String Function() requestId;
  final bool Function() current;
  final Listenable owner;
  List<HomeResourceRecord> items = const [];
  List<String> entities = const [];
  CoreHaTransferPreview? preview;
  CoreHaTransferReceipt? receipt;
  bool busy = false, uncertain = false;
  String? failure;
  Future<void> load({bool more = false}) async {}
  Future<void> prepare(HomeResourceRecord target, String entity, {required bool Function() isCurrent}) async {}
  Future<void> confirm(CoreHaTransferPreview value, {required bool Function() isCurrent}) async {}
  Future<void> cancel(CoreHaTransferPreview value, {required bool Function() isCurrent}) async {}
  Future<void> recover({required bool Function() isCurrent}) async {}
}
