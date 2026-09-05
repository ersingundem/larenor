import '../../dashboard/data/dashboard_repository.dart';

class LegacyLayoutController {
  LegacyLayoutController({required DashboardRepository destination, required bool Function() isCurrent, DateTime Function()? clock});
  Future<LegacyLayoutPreview> preview() async => throw UnimplementedError();
  Future<void> apply(LegacyLayoutPreview preview, Set<int> selected) async => throw UnimplementedError();
  void close() {}
}
class LegacyLayoutPreview {
  List<String> get roomNames => const [];
  List<String> get currentRoomNames => const [];
  int get excludedEntityReferences => 0;
  int get excludedAreaBindings => 0;
}
