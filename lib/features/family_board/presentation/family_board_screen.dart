import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/family_board_controller.dart';
import '../domain/family_board_models.dart';

final class FamilyBoardStrings {
  const FamilyBoardStrings({
    required this.title,
    required this.cards,
    required this.whiteboard,
    required this.newCard,
    required this.editCard,
    required this.save,
    required this.cancel,
    required this.delete,
    required this.addMark,
    required this.refresh,
    required this.offline,
    required this.conflict,
    required this.empty,
    required this.drawingHint,
    required this.loading,
    required this.unavailable,
  });
  factory FamilyBoardStrings.fromLocalizations(AppLocalizations l) =>
      FamilyBoardStrings(
        title: l.familyBoardTitle,
        cards: l.familyBoardCards,
        whiteboard: l.familyBoardWhiteboard,
        newCard: l.familyBoardNewCard,
        editCard: l.familyBoardEditCard,
        save: l.commonSave,
        cancel: l.commonCancel,
        delete: l.commonDelete,
        addMark: l.familyBoardAddMark,
        refresh: l.familyBoardRefresh,
        offline: l.familyBoardOffline,
        conflict: l.familyBoardConflict,
        empty: l.familyBoardEmpty,
        drawingHint: l.familyBoardDrawingHint,
        loading: l.familyBoardLoading,
        unavailable: l.familyBoardUnavailable,
      );
  final String title,
      cards,
      whiteboard,
      newCard,
      editCard,
      save,
      cancel,
      delete,
      addMark,
      refresh,
      offline,
      conflict,
      empty,
      drawingHint,
      loading,
      unavailable;
}

final class FamilyBoardScreen extends StatefulWidget {
  const FamilyBoardScreen({
    super.key,
    required this.controller,
    required this.strings,
  });
  final FamilyBoardController controller;
  final FamilyBoardStrings strings;
  @override
  State<FamilyBoardScreen> createState() => _FamilyBoardScreenState();
}

final class _FamilyBoardScreenState extends State<FamilyBoardScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) widget.controller.retire();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _edit([BoardCard? card]) async {
    if (!widget.controller.canMutate) return;
    final text = TextEditingController(text: card?.text ?? '');
    try {
      final result = await showCupertinoDialog<_EditResult>(
        context: context,
        builder: (context) => _CardEditor(
          strings: widget.strings,
          controller: text,
          editing: card != null,
        ),
      );
      if (!mounted || result == null) return;
      if (result.delete && card != null) {
        final confirmed = await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: Text(widget.strings.delete),
            content: Text(card.text),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: Text(widget.strings.cancel),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(context, true),
                child: Text(widget.strings.delete),
              ),
            ],
          ),
        );
        if (confirmed == true) await widget.controller.deleteElement(card.id);
      } else if (result.text case final value?) {
        if (card == null) {
          await widget.controller.createCard(value);
        } else {
          await widget.controller.updateCard(card.id, value);
        }
      }
    } finally {
      text.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(middle: Text(widget.strings.title)),
    child: SafeArea(
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          return LayoutBuilder(
            builder: (context, constraints) {
              final cards = _cards(context);
              final board = _board(context);
              return SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _status(context, controller),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _action(
                          key: const ValueKey('family-board-new'),
                          label: widget.strings.newCard,
                          icon: CupertinoIcons.add,
                          enabled: controller.canMutate,
                          action: () => _edit(),
                        ),
                        _action(
                          key: const ValueKey('family-board-refresh'),
                          label: widget.strings.refresh,
                          icon: CupertinoIcons.refresh,
                          enabled:
                              !controller.busy && controller.snapshot != null,
                          action: controller.failure == BoardFailure.conflict
                              ? controller.reloadAfterConflict
                              : controller.refreshDelta,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    if (constraints.maxWidth >= 900)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 2, child: cards),
                          const SizedBox(width: 20),
                          Expanded(flex: 3, child: board),
                        ],
                      )
                    else ...[
                      cards,
                      const SizedBox(height: 20),
                      board,
                    ],
                  ],
                ),
              );
            },
          );
        },
      ),
    ),
  );

  Widget _status(BuildContext context, FamilyBoardController controller) {
    final label = controller.offline
        ? widget.strings.offline
        : switch (controller.failure) {
            BoardFailure.conflict => widget.strings.conflict,
            BoardFailure.stale ||
            BoardFailure.invalidResponse ||
            BoardFailure.offline => widget.strings.unavailable,
            null when controller.busy => widget.strings.loading,
            _ => null,
          };
    if (label == null) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(
              controller.offline
                  ? CupertinoIcons.wifi_slash
                  : CupertinoIcons.info_circle,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }

  Widget _cards(BuildContext context) => _panel(
    context,
    widget.strings.cards,
    widget.controller.snapshot?.cards.isEmpty != false
        ? Semantics(
            container: true,
            label: widget.strings.empty,
            child: Text(widget.strings.empty),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final card in widget.controller.snapshot!.cards)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Semantics(
                    button: true,
                    label: '${widget.strings.editCard}: ${card.text}',
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: CupertinoButton(
                        color: _cardColor(context, card.color),
                        foregroundColor: CupertinoColors.label.resolveFrom(
                          context,
                        ),
                        padding: const EdgeInsets.all(16),
                        alignment: AlignmentDirectional.centerStart,
                        onPressed: widget.controller.canMutate
                            ? () => _edit(card)
                            : null,
                        child: ExcludeSemantics(
                          child: Text(card.text, textAlign: TextAlign.start),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
  );

  Widget _board(BuildContext context) => _panel(
    context,
    widget.strings.whiteboard,
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BoardCanvas(
          key: const ValueKey('family-board-canvas'),
          strokes: widget.controller.snapshot?.strokes ?? const [],
          label: widget.strings.drawingHint,
          enabled: widget.controller.canMutate,
          onStroke: widget.controller.appendStroke,
        ),
        const SizedBox(height: 12),
        _action(
          key: const ValueKey('family-board-mark'),
          label: widget.strings.addMark,
          icon: CupertinoIcons.pencil,
          enabled: widget.controller.canMutate,
          action: () => widget.controller.appendStroke(const [
            BoardPoint(32, 48),
            BoardPoint(96, 48),
          ]),
        ),
      ],
    ),
  );

  Widget _panel(BuildContext context, String title, Widget child) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      borderRadius: BorderRadius.circular(22),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
          ),
        ),
        const SizedBox(height: 16),
        child,
      ],
    ),
  );

  Widget _action({
    required Key key,
    required String label,
    required IconData icon,
    required bool enabled,
    required FutureOr<void> Function() action,
  }) => SizedBox(
    key: key,
    height: 48,
    child: CupertinoButton(
      color: CupertinoColors.activeBlue,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      onPressed: enabled ? () => action() : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22),
          const SizedBox(width: 8),
          Flexible(child: Text(label)),
        ],
      ),
    ),
  );

  Color _cardColor(BuildContext context, String color) => switch (color) {
    'blue' => CupertinoColors.systemBlue.withValues(alpha: .18),
    'green' => CupertinoColors.systemGreen.withValues(alpha: .18),
    'pink' => CupertinoColors.systemPink.withValues(alpha: .18),
    'gray' => CupertinoColors.systemGrey.withValues(alpha: .18),
    _ => CupertinoColors.systemYellow.withValues(alpha: .22),
  };
}

final class _EditResult {
  const _EditResult.save(this.text) : delete = false;
  const _EditResult.delete() : text = null, delete = true;
  final String? text;
  final bool delete;
}

final class _CardEditor extends StatefulWidget {
  const _CardEditor({
    required this.strings,
    required this.controller,
    required this.editing,
  });
  final FamilyBoardStrings strings;
  final TextEditingController controller;
  final bool editing;
  @override
  State<_CardEditor> createState() => _CardEditorState();
}

final class _CardEditorState extends State<_CardEditor> {
  bool get valid =>
      widget.controller.text.trim().isNotEmpty &&
      widget.controller.text.runes.length <= 2000;
  void _save() {
    if (valid) Navigator.pop(context, _EditResult.save(widget.controller.text));
  }

  @override
  Widget build(BuildContext context) => CupertinoAlertDialog(
    title: Text(
      widget.editing ? widget.strings.editCard : widget.strings.newCard,
    ),
    content: Padding(
      padding: const EdgeInsets.only(top: 12),
      child: CupertinoTextField(
        key: const ValueKey('family-board-editor'),
        controller: widget.controller,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        maxLength: 2000,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      if (widget.editing)
        CupertinoDialogAction(
          key: const ValueKey('family-board-delete'),
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(context, const _EditResult.delete()),
          child: Text(widget.strings.delete),
        ),
      CupertinoDialogAction(
        onPressed: valid ? _save : null,
        isDefaultAction: true,
        child: Text(widget.strings.save),
      ),
    ],
  );
}

final class _BoardCanvas extends StatefulWidget {
  const _BoardCanvas({
    super.key,
    required this.strokes,
    required this.label,
    required this.enabled,
    required this.onStroke,
  });
  final List<BoardStroke> strokes;
  final String label;
  final bool enabled;
  final Future<void> Function(List<BoardPoint>) onStroke;
  @override
  State<_BoardCanvas> createState() => _BoardCanvasState();
}

final class _BoardCanvasState extends State<_BoardCanvas> {
  final _focus = FocusNode(debugLabel: 'Family whiteboard');
  List<BoardPoint> _points = const [];
  bool _focused = false;
  void _add(Offset point) {
    if (!widget.enabled || _points.length >= 256) return;
    setState(
      () => _points = [
        ..._points,
        BoardPoint(point.dx.clamp(0, 100000), point.dy.clamp(0, 100000)),
      ],
    );
  }

  Future<void> _finish() async {
    final value = _points;
    setState(() => _points = const []);
    if (value.length >= 2) await widget.onStroke(value);
  }

  Future<void> _accessibleMark() =>
      widget.onStroke(const [BoardPoint(32, 48), BoardPoint(96, 48)]);
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    },
    child: Actions(
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (widget.enabled) unawaited(_accessibleMark());
            return null;
          },
        ),
      },
      child: Focus(
        focusNode: _focus,
        onFocusChange: (value) => setState(() => _focused = value),
        child: Semantics(
          button: true,
          enabled: widget.enabled,
          label: widget.label,
          onTap: widget.enabled ? () => unawaited(_accessibleMark()) : null,
          child: GestureDetector(
            onTap: widget.enabled ? () => _focus.requestFocus() : null,
            onPanStart: widget.enabled
                ? (event) => _add(event.localPosition)
                : null,
            onPanUpdate: widget.enabled
                ? (event) => _add(event.localPosition)
                : null,
            onPanEnd: widget.enabled ? (_) => unawaited(_finish()) : null,
            child: Container(
              height: 280,
              decoration: BoxDecoration(
                color: CupertinoColors.systemBackground.resolveFrom(context),
                border: Border.all(
                  color: _focused
                      ? CupertinoColors.activeBlue.resolveFrom(context)
                      : CupertinoColors.separator.resolveFrom(context),
                  width: _focused ? 3 : 1,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: CustomPaint(
                painter: _StrokePainter([
                  ...widget.strokes,
                  if (_points.length >= 2)
                    BoardStroke(
                      id: '00000000000000000000000000000000',
                      color: 'blue',
                      width: 4,
                      points: _points,
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

final class _StrokePainter extends CustomPainter {
  const _StrokePainter(this.strokes);
  final List<BoardStroke> strokes;
  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      final paint = Paint()
        ..color = switch (stroke.color) {
          'red' => CupertinoColors.systemRed,
          'green' => CupertinoColors.systemGreen,
          'white' => CupertinoColors.white,
          'black' => CupertinoColors.black,
          _ => CupertinoColors.systemBlue,
        }
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(
          stroke.points.first.x.clamp(0, size.width),
          stroke.points.first.y.clamp(0, size.height),
        );
      for (final point in stroke.points.skip(1)) {
        path.lineTo(
          point.x.clamp(0, size.width),
          point.y.clamp(0, size.height),
        );
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) =>
      oldDelegate.strokes != strokes;
}
