import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../server/domain/server_models.dart';
import '../domain/floor_plan_editor_models.dart';
import 'floor_plan_api.dart';

enum FloorPlanEditorFailure { offline, conflict, invalidResponse }

final class FloorPlanEditorController extends ChangeNotifier {
  FloorPlanEditorController({
    required this.gateway,
    required this.isCurrent,
    required this.actionSafe,
    String Function()? requestIds,
  }) : _requestIds = requestIds ?? _randomId;

  final FloorPlanEditorGateway gateway;
  final bool Function() isCurrent;
  final bool Function() actionSafe;
  final String Function() _requestIds;
  int _epoch = 0;
  bool _retired = false;
  bool busy = false, saving = false, dirty = false, needsReload = false;
  FloorPlanEditorFailure? failure;
  FloorPlanEditorCatalog? catalog;
  FloorPlanEditorLayout? layout;

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  bool get canMutate =>
      !_retired &&
      !busy &&
      !saving &&
      !needsReload &&
      isCurrent() &&
      actionSafe();

  bool get canSave {
    if (!canMutate || !dirty || catalog == null || layout == null) return false;
    try {
      FloorPlanEditorLayout.fromJson(layout!.toJson());
      return true;
    } on LarenorServerException {
      return false;
    }
  }

  Future<void> load() async {
    if (_retired || busy || !isCurrent() || !actionSafe()) return;
    final operation = ++_epoch;
    busy = true;
    failure = null;
    notifyListeners();
    try {
      final value = await gateway.readEditor();
      if (operation != _epoch || _retired || !isCurrent() || !actionSafe()) {
        return;
      }
      catalog = value;
      layout =
          value.layout ??
          const FloorPlanEditorLayout(
            floors: [],
            rooms: [],
            anchors: [],
            vectors: [],
          );
      dirty = false;
      needsReload = false;
    } catch (error) {
      if (operation != _epoch || _retired) return;
      failure = _failure(error);
    } finally {
      if (operation == _epoch && !_retired) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void addFloor(String label) {
    final value = layout;
    final text = label.trim();
    if (!canMutate ||
        value == null ||
        value.floors.length >= 8 ||
        !_safeLabel(text)) {
      return;
    }
    final id = _requestIds();
    _change(
      FloorPlanEditorLayout(
        floors: [
          ...value.floors,
          FloorPlanEditorFloor(id: id, label: text, order: value.floors.length),
        ],
        rooms: value.rooms,
        anchors: value.anchors,
        vectors: value.vectors,
      ),
    );
  }

  void renameFloor(String floorId, String label) {
    final value = layout;
    final text = label.trim();
    if (!canMutate || value == null || !_safeLabel(text)) return;
    _change(
      FloorPlanEditorLayout(
        floors: [
          for (final floor in value.floors)
            FloorPlanEditorFloor(
              id: floor.id,
              label: floor.id == floorId ? text : floor.label,
              order: floor.order,
            ),
        ],
        rooms: value.rooms,
        anchors: value.anchors,
        vectors: value.vectors,
      ),
    );
  }

  void moveFloor(String floorId, int delta) {
    final value = layout;
    if (!canMutate || value == null) return;
    final ordered = value.floors.toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final from = ordered.indexWhere((item) => item.id == floorId);
    final to = (from + delta).clamp(0, ordered.length - 1);
    if (from < 0 || from == to) return;
    final item = ordered.removeAt(from);
    ordered.insert(to, item);
    _change(
      FloorPlanEditorLayout(
        floors: [
          for (var index = 0; index < ordered.length; index++)
            FloorPlanEditorFloor(
              id: ordered[index].id,
              label: ordered[index].label,
              order: index,
            ),
        ],
        rooms: value.rooms,
        anchors: value.anchors,
        vectors: value.vectors,
      ),
    );
  }

  void removeFloor(String floorId) {
    final value = layout;
    if (!canMutate || value == null) return;
    final roomIds = value.rooms
        .where((item) => item.floorId == floorId)
        .map((item) => item.id)
        .toSet();
    final floors = value.floors.where((item) => item.id != floorId).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    _change(
      FloorPlanEditorLayout(
        floors: [
          for (var index = 0; index < floors.length; index++)
            FloorPlanEditorFloor(
              id: floors[index].id,
              label: floors[index].label,
              order: index,
            ),
        ],
        rooms: value.rooms.where((item) => item.floorId != floorId).toList(),
        anchors: value.anchors
            .where((item) => !roomIds.contains(item.roomId))
            .toList(),
        vectors: value.vectors
            .where((item) => item.floorId != floorId)
            .toList(),
      ),
    );
  }

  void addRoom({
    required FloorPlanEditorRoomCandidate room,
    required String floorId,
    required List<FloorPlanEditorPoint> polygon,
  }) {
    final value = layout;
    final authority = catalog;
    if (!canMutate ||
        value == null ||
        authority == null ||
        value.rooms.length >= 128 ||
        !authority.rooms.any(
          (item) => item.id == room.id && item.revision == room.revision,
        ) ||
        !value.floors.any((item) => item.id == floorId) ||
        value.rooms.any((item) => item.id == room.id) ||
        !_validPoints(polygon, 3, 64)) {
      return;
    }
    _change(
      FloorPlanEditorLayout(
        floors: value.floors,
        rooms: [
          ...value.rooms,
          FloorPlanEditorRoom(
            id: room.id,
            floorId: floorId,
            label: room.label,
            polygon: List.unmodifiable(polygon),
          ),
        ],
        anchors: value.anchors,
        vectors: value.vectors,
      ),
    );
  }

  void updateRoomPoint(String roomId, int index, FloorPlanEditorPoint point) {
    final value = layout;
    if (!canMutate ||
        value == null ||
        !_coordinate(point.x) ||
        !_coordinate(point.y)) {
      return;
    }
    _change(
      FloorPlanEditorLayout(
        floors: value.floors,
        rooms: [
          for (final room in value.rooms)
            if (room.id != roomId || index < 0 || index >= room.polygon.length)
              room
            else
              FloorPlanEditorRoom(
                id: room.id,
                floorId: room.floorId,
                label: room.label,
                polygon: [
                  for (var i = 0; i < room.polygon.length; i++)
                    i == index ? point : room.polygon[i],
                ],
              ),
        ],
        anchors: value.anchors,
        vectors: value.vectors,
      ),
    );
  }

  void removeRoom(String roomId) {
    final value = layout;
    if (!canMutate || value == null) return;
    _change(
      FloorPlanEditorLayout(
        floors: value.floors,
        rooms: value.rooms.where((item) => item.id != roomId).toList(),
        anchors: value.anchors.where((item) => item.roomId != roomId).toList(),
        vectors: value.vectors,
      ),
    );
  }

  void addAnchor({
    required FloorPlanEditorTargetCandidate target,
    required String roomId,
    required FloorPlanEditorPoint point,
  }) {
    final value = layout;
    final authority = catalog;
    if (!canMutate ||
        value == null ||
        authority == null ||
        value.anchors.length >= 512 ||
        !value.rooms.any((item) => item.id == roomId) ||
        !authority.targets.any(
          (item) => item.key == target.key && item.revision == target.revision,
        ) ||
        value.anchors.any(
          (item) =>
              item.targetKind == target.kind && item.targetId == target.id,
        ) ||
        !_coordinate(point.x) ||
        !_coordinate(point.y)) {
      return;
    }
    _change(
      FloorPlanEditorLayout(
        floors: value.floors,
        rooms: value.rooms,
        anchors: [
          ...value.anchors,
          FloorPlanEditorAnchor(
            id: _requestIds(),
            roomId: roomId,
            targetKind: target.kind,
            targetId: target.id,
            targetRevision: target.revision,
            x: point.x,
            y: point.y,
            rotation: 0,
          ),
        ],
        vectors: value.vectors,
      ),
    );
  }

  void moveAnchor(String anchorId, FloorPlanEditorPoint point) {
    final value = layout;
    if (!canMutate ||
        value == null ||
        !_coordinate(point.x) ||
        !_coordinate(point.y)) {
      return;
    }
    _change(
      FloorPlanEditorLayout(
        floors: value.floors,
        rooms: value.rooms,
        anchors: [
          for (final anchor in value.anchors)
            anchor.id == anchorId
                ? anchor.copyWith(x: point.x, y: point.y)
                : anchor,
        ],
        vectors: value.vectors,
      ),
    );
  }

  void rebindAnchor(String anchorId, FloorPlanEditorTargetCandidate target) {
    final value = layout;
    final authority = catalog;
    if (!canMutate ||
        value == null ||
        authority == null ||
        !authority.targets.any(
          (item) => item.key == target.key && item.revision == target.revision,
        ) ||
        value.anchors.any(
          (item) =>
              item.id != anchorId &&
              item.targetKind == target.kind &&
              item.targetId == target.id,
        )) {
      return;
    }
    _change(
      FloorPlanEditorLayout(
        floors: value.floors,
        rooms: value.rooms,
        anchors: [
          for (final anchor in value.anchors)
            anchor.id == anchorId
                ? anchor.copyWith(
                    targetKind: target.kind,
                    targetId: target.id,
                    targetRevision: target.revision,
                  )
                : anchor,
        ],
        vectors: value.vectors,
      ),
    );
  }

  void removeAnchor(String anchorId) {
    final value = layout;
    if (!canMutate || value == null) return;
    _change(
      FloorPlanEditorLayout(
        floors: value.floors,
        rooms: value.rooms,
        anchors: value.anchors.where((item) => item.id != anchorId).toList(),
        vectors: value.vectors,
      ),
    );
  }

  Future<void> save() async {
    if (!canSave) return;
    final operation = ++_epoch;
    final request = FloorPlanEditorSaveRequest.forCatalog(
      requestId: _requestIds(),
      catalog: catalog!,
      layout: layout!,
    );
    saving = true;
    failure = null;
    notifyListeners();
    var reload = false;
    try {
      final receipt = await gateway.saveEditor(request);
      if (operation != _epoch || _retired || !isCurrent() || !actionSafe()) {
        return;
      }
      if (receipt.revision != catalog!.layoutRevision + 1) {
        throw const LarenorServerException('invalid_response');
      }
      dirty = false;
      reload = true;
    } catch (error) {
      if (operation != _epoch || _retired) return;
      failure = _failure(error);
      if (failure == FloorPlanEditorFailure.conflict) needsReload = true;
    } finally {
      if (operation == _epoch && !_retired) {
        saving = false;
        notifyListeners();
      }
    }
    if (reload && operation == _epoch && !_retired && isCurrent()) {
      await load();
    }
  }

  void _change(FloorPlanEditorLayout value) {
    layout = value;
    dirty = true;
    failure = null;
    notifyListeners();
  }

  static bool _safeLabel(String value) =>
      value.isNotEmpty &&
      value.length <= 80 &&
      !value.runes.any((rune) => rune < 32 || rune == 127);

  static bool _coordinate(double value) =>
      value.isFinite && value >= 0 && value <= 1;

  static bool _validPoints(
    List<FloorPlanEditorPoint> points,
    int min,
    int max,
  ) =>
      points.length >= min &&
      points.length <= max &&
      points.every((point) => _coordinate(point.x) && _coordinate(point.y));

  FloorPlanEditorFailure _failure(Object error) =>
      error is LarenorServerException && error.code == 'conflict'
      ? FloorPlanEditorFailure.conflict
      : error is LarenorServerException &&
            {
              'connection_failed',
              'timeout',
              'server_unavailable',
              'server_error',
            }.contains(error.code)
      ? FloorPlanEditorFailure.offline
      : FloorPlanEditorFailure.invalidResponse;

  void retire() {
    if (_retired) return;
    _retired = true;
    _epoch++;
    notifyListeners();
  }

  @override
  void dispose() {
    _retired = true;
    _epoch++;
    super.dispose();
  }
}
