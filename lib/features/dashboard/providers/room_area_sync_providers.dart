import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin/providers/admin_providers.dart';
import '../../auth/data/ha_connection_config.dart';
import '../../auth/providers/auth_providers.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../data/room_area_sync_reader.dart';
import '../domain/dashboard_layout.dart';
import '../domain/ha_area_binding.dart';
import '../domain/room_area_sync.dart';
import 'dashboard_providers.dart';

final roomAreaSyncClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final roomAreaSyncReaderProvider = Provider.autoDispose<RoomAreaSyncReader?>((
  ref,
) {
  final connection = ref.watch(connectionConfigProvider);
  final config = connection.isLoading || connection.hasError
      ? null
      : connection.value;
  final client = ref.watch(haAdminClientProvider);
  if (config == null || client == null) return null;
  bool current() {
    if (!ref.mounted) return false;
    final latest = ref.read(connectionConfigProvider);
    return !latest.isLoading &&
        !latest.hasError &&
        identical(latest.value, config);
  }

  return HaRoomAreaSyncReader(
    client: client,
    serverUrl: config.baseUrl,
    entities: () => ref.read(entitiesProvider.future),
    isCurrent: current,
  );
});

final roomAreaSyncSourceProvider = FutureProvider.autoDispose<AreaSyncSnapshot>(
  (ref) async {
    final reader = ref.watch(roomAreaSyncReaderProvider);
    if (reader == null) throw const RoomAreaSyncException('not_connected');
    return reader.read();
  },
  retry: (_, _) => null,
);

/// An explicit preview is account-, source- and layout-scoped and single-use.
/// Its constructor is private: the UI cannot fabricate approval of another diff.
class RoomAreaSyncPreview {
  RoomAreaSyncPreview._(
    this._owner, {
    required this.change,
    required this.layout,
    required this.source,
    required this.createdAt,
  });
  final RoomAreaSyncChange change;
  final DashboardLayout layout;
  final AreaSyncSnapshot source;
  final DateTime createdAt;
  final Object _owner;
  bool _used = false;
}

final roomAreaSyncControllerProvider =
    Provider.autoDispose<RoomAreaSyncController>((ref) {
      final config = ref.watch(connectionConfigProvider);
      final reader = ref.watch(roomAreaSyncReaderProvider);
      // Keep the preview source alive while the controller is used, without
      // replacing the controller owner when a read resolves or is refreshed.
      ref.listen(roomAreaSyncSourceProvider, (_, _) {});
      final controller = RoomAreaSyncController(ref, config.value, reader);
      ref.onDispose(controller.close);
      return controller;
    });

class RoomAreaSyncController {
  RoomAreaSyncController(this.ref, this.config, this.reader);
  final Ref ref;
  final HaConnectionConfig? config;
  final RoomAreaSyncReader? reader;
  final _owner = Object();
  bool _closed = false;
  void close() {
    _closed = true;
  }

  bool get _current {
    if (_closed || !ref.mounted || config == null) return false;
    final value = ref.read(connectionConfigProvider);
    return !value.isLoading &&
        !value.hasError &&
        identical(value.value, config);
  }

  Future<RoomAreaSyncPreview> preview({
    required String roomId,
    required String areaId,
  }) async {
    if (!_current) throw const RoomAreaSyncException('account_changed');
    final AreaSyncSnapshot source;
    try {
      source = await ref.read(roomAreaSyncSourceProvider.future);
    } catch (_) {
      if (!_current) throw const RoomAreaSyncException('account_changed');
      rethrow;
    }
    if (!_current) throw const RoomAreaSyncException('account_changed');
    if (source.serverUrl != normalizedAreaServerUrl(config!.baseUrl)) {
      throw const RoomAreaSyncException('account_changed');
    }
    final layout = await ref.read(dashboardRepositoryProvider).load();
    if (!_current) throw const RoomAreaSyncException('account_changed');
    final room = layout.rooms.where((room) => room.id == roomId).firstOrNull;
    if (room == null) throw const RoomAreaSyncException('layout_changed');
    final change = buildRoomAreaSyncChange(
      room: room,
      snapshot: source,
      areaId: areaId,
    );
    return RoomAreaSyncPreview._(
      _owner,
      change: change,
      layout: layout,
      source: source,
      createdAt: ref.read(roomAreaSyncClockProvider)(),
    );
  }

  Future<void> apply(RoomAreaSyncPreview preview) async {
    if (!_current || reader == null || !identical(preview._owner, _owner)) {
      throw const RoomAreaSyncException('account_changed');
    }
    final now = ref.read(roomAreaSyncClockProvider)();
    if (preview._used ||
        now.isBefore(preview.createdAt) ||
        now.difference(preview.createdAt) > const Duration(minutes: 5)) {
      throw const RoomAreaSyncException('preview_expired');
    }
    final cached = ref.read(roomAreaSyncSourceProvider);
    if (cached.isLoading ||
        cached.hasError ||
        !identical(cached.value, preview.source)) {
      throw const RoomAreaSyncException('source_changed');
    }
    preview._used = true;
    if (preview.change.missingArea) {
      throw const RoomAreaSyncException('missing_area');
    }
    final fresh = await reader!.read();
    if (!_current) throw const RoomAreaSyncException('account_changed');
    final currentChange = buildRoomAreaSyncChange(
      room: preview.change.before,
      snapshot: fresh,
      areaId: preview.change.after.areaBinding!.areaId,
    );
    if (currentChange.missingArea ||
        currentChange.after != preview.change.after ||
        !_same(currentChange.heldUnknown, preview.change.heldUnknown)) {
      throw const RoomAreaSyncException('source_changed');
    }
    await ref
        .read(dashboardLayoutProvider.notifier)
        .applyAreaSyncChange(
          preview.layout,
          currentChange.after,
          isCurrent: () => _current,
        );
  }
}

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
