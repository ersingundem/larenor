import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../data/floor_plan_controller.dart';
import '../domain/floor_plan_models.dart';

final class FloorPlanStrings {
  const FloorPlanStrings({
    required this.title,
    required this.loading,
    required this.empty,
    required this.offline,
    required this.stale,
    required this.invalid,
    required this.refresh,
    required this.zoomIn,
    required this.zoomOut,
    required this.accessibleRooms,
    this.floors = 'Floors',
  });
  factory FloorPlanStrings.fromLocalizations(AppLocalizations value) =>
      FloorPlanStrings(
        title: value.floorPlanTitle,
        loading: value.floorPlanLoading,
        empty: value.floorPlanEmpty,
        offline: value.floorPlanOffline,
        stale: value.floorPlanStale,
        invalid: value.floorPlanInvalid,
        refresh: value.floorPlanRefresh,
        zoomIn: value.floorPlanZoomIn,
        zoomOut: value.floorPlanZoomOut,
        accessibleRooms: value.floorPlanAccessibleRooms,
        floors: value.floorPlanFloors,
      );
  final String title, loading, empty, offline, stale, invalid;
  final String refresh, zoomIn, zoomOut, accessibleRooms, floors;
}

final class FloorPlanScreen extends StatefulWidget {
  const FloorPlanScreen({
    super.key,
    required this.controller,
    required this.strings,
  });
  final FloorPlanController controller;
  final FloorPlanStrings strings;

  @override
  State<FloorPlanScreen> createState() => _FloorPlanScreenState();
}

final class _FloorPlanScreenState extends State<FloorPlanScreen> {
  final TransformationController _transform = TransformationController();
  double _scale = 1;
  String? _selectedFloorId;
  String? _selectedAnchorId;

  @override
  void initState() {
    super.initState();
    if (widget.controller.snapshot == null && !widget.controller.busy) {
      unawaited(widget.controller.load());
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _zoom(double delta) {
    final next = (_scale + delta).clamp(0.75, 3.0);
    setState(() {
      _scale = next;
      _transform.value = Matrix4.diagonal3Values(next, next, 1);
    });
  }

  void _selectFloor(String floorId) {
    if (_selectedFloorId == floorId) return;
    setState(() {
      _selectedFloorId = floorId;
      _selectedAnchorId = null;
      _scale = 1;
      _transform.value = Matrix4.identity();
    });
  }

  void _selectAnchor(String anchorId) {
    if (_selectedAnchorId == anchorId) return;
    setState(() => _selectedAnchorId = anchorId);
  }

  String _failure(FloorPlanFailure value) => switch (value) {
    FloorPlanFailure.offline => widget.strings.offline,
    FloorPlanFailure.stale => widget.strings.stale,
    FloorPlanFailure.invalidResponse => widget.strings.invalid,
  };

  @override
  Widget build(BuildContext context) => AppPageScaffold(
    navigationBar: CupertinoNavigationBar(middle: Text(widget.strings.title)),
    child: SafeArea(
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final snapshot = widget.controller.snapshot;
            final controls = _controls();
            final content = snapshot == null
                ? _status()
                : _content(snapshot, constraints.maxWidth >= 900);
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [controls, const SizedBox(height: 16), content],
              ),
            );
          },
        ),
      ),
    ),
  );

  Widget _controls() => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.equal): _ZoomIntent(0.25),
      SingleActivator(LogicalKeyboardKey.numpadAdd): _ZoomIntent(0.25),
      SingleActivator(LogicalKeyboardKey.minus): _ZoomIntent(-0.25),
      SingleActivator(LogicalKeyboardKey.numpadSubtract): _ZoomIntent(-0.25),
    },
    child: Actions(
      actions: {
        _ZoomIntent: CallbackAction<_ZoomIntent>(
          onInvoke: (intent) {
            _zoom(intent.delta);
            return null;
          },
        ),
      },
      child: Focus(
        autofocus: true,
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _button(
              const ValueKey('floor-plan-refresh'),
              widget.strings.refresh,
              widget.controller.busy
                  ? null
                  : () => unawaited(widget.controller.load()),
            ),
            _button(
              const ValueKey('floor-plan-zoom-in'),
              widget.strings.zoomIn,
              () => _zoom(0.25),
            ),
            _button(
              const ValueKey('floor-plan-zoom-out'),
              widget.strings.zoomOut,
              () => _zoom(-0.25),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _button(Key key, String label, VoidCallback? action) => Semantics(
    button: true,
    label: label,
    child: SizedBox(
      key: key,
      height: 48,
      child: CupertinoButton(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        color: CupertinoColors.secondarySystemGroupedBackground,
        onPressed: action,
        child: ExcludeSemantics(child: Text(label)),
      ),
    ),
  );

  Widget _status() {
    final failure = widget.controller.failure;
    final text = widget.controller.busy
        ? widget.strings.loading
        : failure == null
        ? widget.strings.empty
        : _failure(failure);
    return Semantics(
      liveRegion: true,
      label: text,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: widget.controller.busy
              ? const CupertinoActivityIndicator()
              : Text(text, textAlign: TextAlign.center),
        ),
      ),
    );
  }

  Widget _content(FloorPlanSnapshot snapshot, bool wide) {
    final floors = snapshot.floors.toList(growable: false)
      ..sort((left, right) {
        final byOrder = left.order.compareTo(right.order);
        if (byOrder != 0) return byOrder;
        final byLabel = left.label.compareTo(right.label);
        return byLabel != 0 ? byLabel : left.id.compareTo(right.id);
      });
    final selectedFloorId = floors.any((floor) => floor.id == _selectedFloorId)
        ? _selectedFloorId!
        : floors.first.id;
    _selectedFloorId = selectedFloorId;
    final rooms = snapshot.rooms
        .where((room) => room.floorId == selectedFloorId)
        .toList(growable: false);
    final roomIds = rooms.map((room) => room.id).toSet();
    final anchors = snapshot.anchors
        .where((anchor) => roomIds.contains(anchor.roomId))
        .toList(growable: false);
    final vectors = snapshot.vectors
        .where((vector) => vector.floorId == selectedFloorId)
        .toList(growable: false);
    if (!anchors.any((anchor) => anchor.id == _selectedAnchorId)) {
      _selectedAnchorId = null;
    }
    final floorSelector = Semantics(
      container: true,
      label: widget.strings.floors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(
            child: Text(
              widget.strings.floors,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final floor in floors)
                Semantics(
                  selected: floor.id == selectedFloorId,
                  label: floor.label,
                  child: SizedBox(
                    height: 48,
                    child: CupertinoButton(
                      key: ValueKey('floor-plan-floor-${floor.id}'),
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      color: floor.id == selectedFloorId
                          ? CupertinoColors.activeBlue
                          : CupertinoColors.secondarySystemGroupedBackground,
                      onPressed: () => _selectFloor(floor.id),
                      child: ExcludeSemantics(child: Text(floor.label)),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
    final canvas = Container(
      key: const ValueKey('floor-plan-canvas'),
      constraints: const BoxConstraints(minHeight: 360),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 0.75,
        maxScale: 3,
        constrained: true,
        child: SizedBox(
          height: 420,
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: _FloorPlanPainter(
                    snapshot: snapshot,
                    floorId: selectedFloorId,
                    rooms: rooms,
                    vectors: vectors,
                  ),
                  child: const SizedBox.expand(),
                ),
                for (final anchor in anchors)
                  _anchorTarget(
                    anchor,
                    constraints.biggest,
                    selected: anchor.id == _selectedAnchorId,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final list = Semantics(
      container: true,
      label: widget.strings.accessibleRooms,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.strings.accessibleRooms,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          for (final room in rooms)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Semantics(
                header: true,
                child: Text(
                  room.label,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          for (final anchor in anchors)
            Semantics(
              selected: anchor.id == _selectedAnchorId,
              label: '${anchor.targetKind}: ${anchor.targetId}',
              child: SizedBox(
                height: 48,
                child: CupertinoButton(
                  key: ValueKey('floor-plan-anchor-list-${anchor.id}'),
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: AlignmentDirectional.centerStart,
                  onPressed: () => _selectAnchor(anchor.id),
                  child: ExcludeSemantics(
                    child: Text('${anchor.targetKind}: ${anchor.targetId}'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          floorSelector,
          const SizedBox(height: 16),
          canvas,
          const SizedBox(height: 20),
          list,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        floorSelector,
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: canvas),
            const SizedBox(width: 24),
            Expanded(flex: 2, child: list),
          ],
        ),
      ],
    );
  }

  Widget _anchorTarget(
    FloorPlanAnchor anchor,
    Size canvasSize, {
    required bool selected,
  }) {
    const targetSize = 64.0;
    const radius = 8.0;
    final x = anchor.x * canvasSize.width;
    final y = anchor.y * canvasSize.height;
    final left = (x - targetSize / 2)
        .clamp(0.0, (canvasSize.width - targetSize).clamp(0.0, double.infinity))
        .toDouble();
    final top = (y - targetSize / 2)
        .clamp(
          0.0,
          (canvasSize.height - targetSize).clamp(0.0, double.infinity),
        )
        .toDouble();
    final dotLeft = (x - left - radius)
        .clamp(0.0, targetSize - radius * 2)
        .toDouble();
    final dotTop = (y - top - radius)
        .clamp(0.0, targetSize - radius * 2)
        .toDouble();
    return Positioned(
      left: left,
      top: top,
      width: targetSize,
      height: targetSize,
      child: Semantics(
        selected: selected,
        label: '${anchor.targetKind}: ${anchor.targetId}',
        child: CupertinoButton(
          key: ValueKey('floor-plan-anchor-${anchor.id}'),
          minimumSize: const Size(targetSize, targetSize),
          padding: EdgeInsets.zero,
          onPressed: () => _selectAnchor(anchor.id),
          child: ExcludeSemantics(
            child: SizedBox(
              width: targetSize,
              height: targetSize,
              child: Stack(
                children: [
                  Positioned(
                    left: dotLeft,
                    top: dotTop,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: selected
                            ? CupertinoColors.systemOrange
                            : const Color(0xFF0A84FF),
                        shape: BoxShape.circle,
                        border: selected
                            ? Border.all(color: CupertinoColors.white, width: 2)
                            : null,
                      ),
                      child: const SizedBox(
                        width: radius * 2,
                        height: radius * 2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ZoomIntent extends Intent {
  const _ZoomIntent(this.delta);
  final double delta;
}

final class _FloorPlanPainter extends CustomPainter {
  const _FloorPlanPainter({
    required this.snapshot,
    required this.floorId,
    required this.rooms,
    required this.vectors,
  });
  final FloorPlanSnapshot snapshot;
  final String floorId;
  final List<FloorPlanRoom> rooms;
  final List<FloorPlanVector> vectors;

  @override
  void paint(Canvas canvas, Size size) {
    final roomPaint = Paint()
      ..color = const Color(0x222A8CFF)
      ..style = PaintingStyle.fill;
    final wallPaint = Paint()
      ..color = CupertinoColors.systemGrey
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    for (final room in rooms) {
      final path = Path()
        ..moveTo(
          room.polygon.first.x * size.width,
          room.polygon.first.y * size.height,
        );
      for (final point in room.polygon.skip(1)) {
        path.lineTo(point.x * size.width, point.y * size.height);
      }
      canvas.drawPath(path..close(), roomPaint);
    }
    for (final vector in vectors) {
      final path = Path()
        ..moveTo(
          vector.points.first.x * size.width,
          vector.points.first.y * size.height,
        );
      for (final point in vector.points.skip(1)) {
        path.lineTo(point.x * size.width, point.y * size.height);
      }
      canvas.drawPath(path, wallPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FloorPlanPainter oldDelegate) =>
      oldDelegate.snapshot.revision != snapshot.revision ||
      oldDelegate.snapshot.context != snapshot.context ||
      oldDelegate.floorId != floorId;
}
