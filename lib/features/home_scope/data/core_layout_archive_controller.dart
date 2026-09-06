import '../../dashboard/data/dashboard_repository.dart';
import '../domain/core_layout_archive.dart';

/// Controller contract; the runtime RED checkpoint rejects every operation.
class CoreLayoutArchiveController {
  CoreLayoutArchiveController({
    required DashboardRepository destination,
    required bool Function() isCurrent,
    DateTime Function()? clock,
  }) {
    if (destination.scope == null) {
      throw const DashboardStorageException('expired');
    }
  }

  static const lifetime = Duration(minutes: 5);
  void close() {}
  Future<CoreLayoutArchiveV1> capture() =>
      Future.error(const DashboardStorageException('expired'));
  Future<CoreLayoutArchivePreview> preview(CoreLayoutArchiveV1 archive) =>
      Future.error(const DashboardStorageException('expired'));
  Future<void> apply(CoreLayoutArchivePreview preview) =>
      Future.error(const DashboardStorageException('expired'));
}

final class CoreLayoutArchivePreview {
  const CoreLayoutArchivePreview._();
  List<String> get currentRoomNames => const [];
  List<String> get archivedRoomNames => const [];
  DateTime get createdAt => DateTime.utc(2026);
}
