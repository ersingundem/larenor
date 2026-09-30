import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/floor_plan_editor_controller.dart';
import '../domain/floor_plan_editor_models.dart';

final class FloorPlanEditor extends StatefulWidget {
  const FloorPlanEditor({
    super.key,
    required this.controller,
    required this.onDone,
  });

  final FloorPlanEditorController controller;
  final VoidCallback onDone;

  @override
  State<FloorPlanEditor> createState() => _FloorPlanEditorState();
}

final class _FloorPlanEditorState extends State<FloorPlanEditor> {
  String? _floorId;
  FloorPlanEditorRoomCandidate? _drawingRoom;
  final List<FloorPlanEditorPoint> _drawingPoints = [];
  FloorPlanEditorTargetCandidate? _placingTarget;
  String? _placingRoomId;

  @override
  void initState() {
    super.initState();
    if (widget.controller.catalog == null && !widget.controller.busy) {
      unawaited(widget.controller.load());
    }
  }

  Future<String?> _labelDialog({String initial = ''}) async {
    final l10n = AppLocalizations.of(context);
    final text = TextEditingController(text: initial);
    final result = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.floorPlanEditorFloorLabel),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            key: const ValueKey('floor-plan-editor-floor-label'),
            controller: text,
            maxLength: 80,
            autofocus: true,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(CupertinoLocalizations.of(context).cancelButtonLabel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialogContext, text.text.trim()),
            child: Text(l10n.commonDone),
          ),
        ],
      ),
    );
    text.dispose();
    return result?.trim().isEmpty == false ? result!.trim() : null;
  }

  Future<T?> _choose<T>({
    required String title,
    required List<T> values,
    required String Function(T) label,
  }) => showCupertinoModalPopup<T>(
    context: context,
    builder: (sheetContext) => CupertinoActionSheet(
      title: Text(title),
      actions: [
        for (final value in values)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheetContext, value),
            child: Text(label(value)),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(sheetContext),
        child: Text(CupertinoLocalizations.of(context).cancelButtonLabel),
      ),
    ),
  );

  Future<void> _addFloor() async {
    final label = await _labelDialog();
    if (label == null || !mounted) return;
    widget.controller.addFloor(label);
  }

  Future<void> _renameFloor(FloorPlanEditorFloor floor) async {
    final label = await _labelDialog(initial: floor.label);
    if (label == null || !mounted) return;
    widget.controller.renameFloor(floor.id, label);
  }

  Future<void> _startRoom() async {
    final catalog = widget.controller.catalog;
    final layout = widget.controller.layout;
    if (catalog == null || layout == null || _selectedFloor(layout) == null) {
      return;
    }
    final used = layout.rooms.map((item) => item.id).toSet();
    final available = catalog.rooms
        .where((item) => !used.contains(item.id))
        .toList();
    final l10n = AppLocalizations.of(context);
    if (available.isEmpty) {
      _announce(l10n.floorPlanEditorNoRooms);
      return;
    }
    final selected = await _choose(
      title: l10n.floorPlanEditorAddRoom,
      values: available,
      label: (item) => item.label,
    );
    if (selected == null || !mounted) return;
    setState(() {
      _drawingRoom = selected;
      _drawingPoints.clear();
      _placingTarget = null;
      _placingRoomId = null;
    });
  }

  void _finishRoom() {
    final room = _drawingRoom;
    final floor = _floorId;
    if (room == null || floor == null || _drawingPoints.length < 3) return;
    widget.controller.addRoom(
      room: room,
      floorId: floor,
      polygon: List.unmodifiable(_drawingPoints),
    );
    setState(() {
      _drawingRoom = null;
      _drawingPoints.clear();
    });
  }

  Future<void> _startTarget() async {
    final catalog = widget.controller.catalog;
    final layout = widget.controller.layout;
    if (catalog == null || layout == null) return;
    final floor = _selectedFloor(layout);
    final rooms = layout.rooms
        .where((item) => item.floorId == floor?.id)
        .toList();
    if (rooms.isEmpty) {
      _announce(AppLocalizations.of(context).floorPlanEditorNeedRoom);
      return;
    }
    final used = layout.anchors
        .map((item) => '${item.targetKind}\u0000${item.targetId}')
        .toSet();
    final targets = catalog.targets
        .where((item) => !used.contains(item.key))
        .toList();
    if (targets.isEmpty) {
      _announce(AppLocalizations.of(context).floorPlanEditorNoTargets);
      return;
    }
    final target = await _choose(
      title: AppLocalizations.of(context).floorPlanEditorAddDevice,
      values: targets,
      label: (item) => item.label,
    );
    if (target == null || !mounted) return;
    final room = rooms.length == 1
        ? rooms.single
        : await _choose(
            title: AppLocalizations.of(context).floorPlanEditorAddRoom,
            values: rooms,
            label: (item) => item.label,
          );
    if (room == null || !mounted) return;
    setState(() {
      _placingTarget = target;
      _placingRoomId = room.id;
      _drawingRoom = null;
      _drawingPoints.clear();
    });
  }

  Future<void> _anchorMenu(FloorPlanEditorAnchor anchor) async {
    final l10n = AppLocalizations.of(context);
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(anchor.targetId),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheetContext, 'rebind'),
            child: Text(l10n.floorPlanEditorRebind),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(sheetContext, 'remove'),
            child: Text(l10n.floorPlanEditorRemove),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: Text(CupertinoLocalizations.of(context).cancelButtonLabel),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'remove') {
      widget.controller.removeAnchor(anchor.id);
      return;
    }
    final layout = widget.controller.layout!;
    final used = layout.anchors
        .where((item) => item.id != anchor.id)
        .map((item) => '${item.targetKind}\u0000${item.targetId}')
        .toSet();
    final target = await _choose(
      title: l10n.floorPlanEditorRebind,
      values: widget.controller.catalog!.targets
          .where((item) => !used.contains(item.key))
          .toList(),
      label: (item) => item.label,
    );
    if (target != null && mounted) {
      widget.controller.rebindAnchor(anchor.id, target);
    }
  }

  void _announce(String message) {
    if (!mounted) return;
    showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(AppLocalizations.of(context).commonDone),
          ),
        ],
      ),
    );
  }

  FloorPlanEditorFloor? _selectedFloor(FloorPlanEditorLayout layout) {
    if (layout.floors.isEmpty) {
      _floorId = null;
      return null;
    }
    final ordered = layout.floors.toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    if (!ordered.any((item) => item.id == _floorId)) {
      _floorId = ordered.first.id;
    }
    return ordered.firstWhere((item) => item.id == _floorId);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final layout = widget.controller.layout;
      final failure = widget.controller.failure;
      if (widget.controller.busy && layout == null) {
        return const Center(child: CupertinoActivityIndicator());
      }
      if (layout == null) {
        return _status(
          failure == FloorPlanEditorFailure.offline
              ? l10n.floorPlanOffline
              : l10n.floorPlanEditorInvalid,
        );
      }
      final selected = _selectedFloor(layout);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _button(
                const ValueKey('floor-plan-editor-done'),
                l10n.floorPlanEditorDone,
                widget.onDone,
              ),
              _button(
                const ValueKey('floor-plan-editor-save'),
                l10n.floorPlanEditorSave,
                widget.controller.canSave
                    ? () => unawaited(widget.controller.save())
                    : null,
              ),
              _button(
                const ValueKey('floor-plan-editor-reload'),
                l10n.floorPlanEditorReload,
                widget.controller.saving
                    ? null
                    : () => unawaited(widget.controller.load()),
              ),
              _button(
                const ValueKey('floor-plan-editor-add-floor'),
                l10n.floorPlanEditorAddFloor,
                widget.controller.canMutate
                    ? () => unawaited(_addFloor())
                    : null,
              ),
              if (selected != null) ...[
                _button(
                  const ValueKey('floor-plan-editor-add-room'),
                  l10n.floorPlanEditorAddRoom,
                  widget.controller.canMutate
                      ? () => unawaited(_startRoom())
                      : null,
                ),
                _button(
                  const ValueKey('floor-plan-editor-add-device'),
                  l10n.floorPlanEditorAddDevice,
                  widget.controller.canMutate
                      ? () => unawaited(_startTarget())
                      : null,
                ),
              ],
              if (_drawingRoom != null)
                _button(
                  const ValueKey('floor-plan-editor-finish-room'),
                  l10n.floorPlanEditorFinishRoom,
                  _drawingPoints.length >= 3 ? _finishRoom : null,
                ),
            ],
          ),
          if (widget.controller.dirty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(l10n.floorPlanEditorUnsaved),
            ),
          if (failure != null || widget.controller.needsReload)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  widget.controller.needsReload
                      ? l10n.floorPlanEditorConflict
                      : failure == FloorPlanEditorFailure.offline
                      ? l10n.floorPlanOffline
                      : l10n.floorPlanEditorInvalid,
                ),
              ),
            ),
          const SizedBox(height: 16),
          _floors(layout, selected),
          const SizedBox(height: 16),
          if (selected == null)
            _status(l10n.floorPlanEditorNeedRoom)
          else ...[
            if (_drawingRoom != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(l10n.floorPlanEditorDrawRoom),
              ),
            if (_placingTarget != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(l10n.floorPlanEditorPlaceDevice),
              ),
            _canvas(layout, selected),
            const SizedBox(height: 16),
            _inventory(layout, selected),
          ],
        ],
      );
    },
  );

  Widget _floors(FloorPlanEditorLayout layout, FloorPlanEditorFloor? selected) {
    final l10n = AppLocalizations.of(context);
    final floors = layout.floors.toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final floor in floors)
          Semantics(
            selected: floor.id == selected?.id,
            label: floor.label,
            child: CupertinoButton(
              key: ValueKey('floor-plan-editor-floor-${floor.id}'),
              color: floor.id == selected?.id
                  ? CupertinoColors.activeBlue
                  : CupertinoColors.secondarySystemGroupedBackground,
              onPressed: () => setState(() {
                _floorId = floor.id;
                _drawingRoom = null;
                _drawingPoints.clear();
                _placingTarget = null;
              }),
              child: Text(floor.label),
            ),
          ),
        if (selected != null)
          CupertinoButton(
            onPressed: widget.controller.canMutate
                ? () => unawaited(_renameFloor(selected))
                : null,
            child: Text(l10n.floorPlanEditorRenameFloor),
          ),
        if (selected != null)
          CupertinoButton(
            onPressed: widget.controller.canMutate
                ? () => widget.controller.moveFloor(selected.id, -1)
                : null,
            child: Text(l10n.floorPlanEditorMoveUp),
          ),
        if (selected != null)
          CupertinoButton(
            onPressed: widget.controller.canMutate
                ? () => widget.controller.moveFloor(selected.id, 1)
                : null,
            child: Text(l10n.floorPlanEditorMoveDown),
          ),
        if (selected != null)
          CupertinoButton(
            onPressed: widget.controller.canMutate
                ? () => widget.controller.removeFloor(selected.id)
                : null,
            child: Text(l10n.floorPlanEditorRemove),
          ),
      ],
    );
  }

  Widget _canvas(
    FloorPlanEditorLayout layout,
    FloorPlanEditorFloor floor,
  ) => Container(
    key: const ValueKey('floor-plan-editor-canvas'),
    height: 420,
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground,
      borderRadius: BorderRadius.circular(20),
    ),
    clipBehavior: Clip.antiAlias,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final rooms = layout.rooms
            .where((item) => item.floorId == floor.id)
            .toList();
        final roomIds = rooms.map((item) => item.id).toSet();
        final anchors = layout.anchors
            .where((item) => roomIds.contains(item.roomId))
            .toList();
        FloorPlanEditorPoint position(Offset value) => FloorPlanEditorPoint(
          (value.dx / size.width).clamp(0, 1),
          (value.dy / size.height).clamp(0, 1),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.controller.canMutate
              ? (details) {
                  final point = position(details.localPosition);
                  if (_drawingRoom != null && _drawingPoints.length < 64) {
                    setState(() => _drawingPoints.add(point));
                  } else if (_placingTarget != null && _placingRoomId != null) {
                    widget.controller.addAnchor(
                      target: _placingTarget!,
                      roomId: _placingRoomId!,
                      point: point,
                    );
                    setState(() {
                      _placingTarget = null;
                      _placingRoomId = null;
                    });
                  }
                }
              : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _EditorPainter(
                  rooms: rooms,
                  vectors: layout.vectors
                      .where((item) => item.floorId == floor.id)
                      .toList(),
                  drawing: _drawingPoints,
                ),
              ),
              for (final room in rooms)
                for (var index = 0; index < room.polygon.length; index++)
                  _handle(
                    key: ValueKey('floor-plan-editor-room-${room.id}-$index'),
                    label: '${room.label} ${index + 1}',
                    point: room.polygon[index],
                    size: size,
                    onMove: (delta) => widget.controller.updateRoomPoint(
                      room.id,
                      index,
                      FloorPlanEditorPoint(
                        (room.polygon[index].x + delta.dx / size.width).clamp(
                          0,
                          1,
                        ),
                        (room.polygon[index].y + delta.dy / size.height).clamp(
                          0,
                          1,
                        ),
                      ),
                    ),
                  ),
              for (final anchor in anchors) _anchor(anchor, size),
            ],
          ),
        );
      },
    ),
  );

  Widget _handle({
    required Key key,
    required String label,
    required FloorPlanEditorPoint point,
    required Size size,
    required ValueChanged<Offset> onMove,
  }) => Positioned(
    left: (point.x * size.width - 22).clamp(0, size.width - 44),
    top: (point.y * size.height - 22).clamp(0, size.height - 44),
    width: 44,
    height: 44,
    child: Semantics(
      label: label,
      enabled: widget.controller.canMutate,
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onPanUpdate: widget.controller.canMutate
            ? (event) => onMove(event.delta)
            : null,
        child: const Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: CupertinoColors.activeBlue,
              shape: BoxShape.circle,
            ),
            child: SizedBox(width: 14, height: 14),
          ),
        ),
      ),
    ),
  );

  Widget _anchor(FloorPlanEditorAnchor anchor, Size size) {
    final key = '${anchor.targetKind}\u0000${anchor.targetId}';
    final label = widget.controller.catalog?.targets
        .where((item) => item.key == key)
        .firstOrNull
        ?.label;
    return Positioned(
      left: (anchor.x * size.width - 24).clamp(0, size.width - 48),
      top: (anchor.y * size.height - 24).clamp(0, size.height - 48),
      width: 48,
      height: 48,
      child: Semantics(
        button: true,
        enabled: widget.controller.canMutate,
        label: label ?? anchor.targetId,
        child: GestureDetector(
          key: ValueKey('floor-plan-editor-anchor-${anchor.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.controller.canMutate
              ? () => unawaited(_anchorMenu(anchor))
              : null,
          onPanUpdate: widget.controller.canMutate
              ? (event) => widget.controller.moveAnchor(
                  anchor.id,
                  FloorPlanEditorPoint(
                    (anchor.x + event.delta.dx / size.width).clamp(0, 1),
                    (anchor.y + event.delta.dy / size.height).clamp(0, 1),
                  ),
                )
              : null,
          child: const Center(
            child: ExcludeSemantics(child: Icon(CupertinoIcons.lightbulb_fill)),
          ),
        ),
      ),
    );
  }

  Widget _inventory(FloorPlanEditorLayout layout, FloorPlanEditorFloor floor) {
    final l10n = AppLocalizations.of(context);
    final rooms = layout.rooms
        .where((item) => item.floorId == floor.id)
        .toList();
    final roomIds = rooms.map((item) => item.id).toSet();
    final targets = {
      for (final item
          in widget.controller.catalog?.targets ??
              const <FloorPlanEditorTargetCandidate>[])
        item.key: item,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final room in rooms)
          DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: CupertinoColors.separator),
              ),
            ),
            child: Row(
              children: [
                Expanded(child: Text(room.label)),
                CupertinoButton(
                  onPressed: widget.controller.canMutate
                      ? () => widget.controller.removeRoom(room.id)
                      : null,
                  child: Text(l10n.floorPlanEditorRemove),
                ),
              ],
            ),
          ),
        for (final anchor in layout.anchors.where(
          (item) => roomIds.contains(item.roomId),
        ))
          DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: CupertinoColors.separator),
              ),
            ),
            child: CupertinoListTile(
              title: Text(
                targets['${anchor.targetKind}\u0000${anchor.targetId}']
                        ?.label ??
                    anchor.targetId,
              ),
              subtitle:
                  targets.containsKey(
                    '${anchor.targetKind}\u0000${anchor.targetId}',
                  )
                  ? null
                  : Text(l10n.floorPlanEditorStaleAnchor),
              trailing: CupertinoButton(
                onPressed: widget.controller.canMutate
                    ? () => unawaited(_anchorMenu(anchor))
                    : null,
                child: Text(l10n.floorPlanEditorRebind),
              ),
            ),
          ),
      ],
    );
  }

  Widget _status(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Semantics(
        liveRegion: true,
        child: Text(text, textAlign: TextAlign.center),
      ),
    ),
  );

  Widget _button(Key key, String text, VoidCallback? onPressed) => SizedBox(
    key: key,
    height: 48,
    child: CupertinoButton(
      minimumSize: const Size(48, 48),
      color: CupertinoColors.secondarySystemGroupedBackground,
      onPressed: onPressed,
      child: Text(text),
    ),
  );
}

final class _EditorPainter extends CustomPainter {
  const _EditorPainter({
    required this.rooms,
    required this.vectors,
    required this.drawing,
  });

  final List<FloorPlanEditorRoom> rooms;
  final List<FloorPlanEditorVector> vectors;
  final List<FloorPlanEditorPoint> drawing;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = const Color(0x222A8CFF);
    final line = Paint()
      ..color = CupertinoColors.systemGrey
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    void path(
      List<FloorPlanEditorPoint> points, {
      required bool close,
      Paint? paint,
    }) {
      if (points.isEmpty) return;
      final value = Path()
        ..moveTo(points.first.x * size.width, points.first.y * size.height);
      for (final point in points.skip(1)) {
        value.lineTo(point.x * size.width, point.y * size.height);
      }
      if (close) value.close();
      canvas.drawPath(value, paint ?? line);
    }

    for (final room in rooms) {
      path(room.polygon, close: true, paint: fill);
      path(room.polygon, close: true);
    }
    for (final vector in vectors) {
      path(vector.points, close: false);
    }
    path(drawing, close: false);
  }

  @override
  bool shouldRepaint(covariant _EditorPainter oldDelegate) => true;
}
