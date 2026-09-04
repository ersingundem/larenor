import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/category_colors.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';
import 'tile_action_support.dart';

class ClimateTile extends ConsumerStatefulWidget {
  const ClimateTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<ClimateTile> createState() => _ClimateTileState();
}

class _ClimateTileState extends ConsumerState<ClimateTile>
    with TileActionSupport<ClimateTile> {
  @override
  String? get actionEntityId => widget.tile.entityId;
  @override
  void didUpdateWidget(covariant ClimateTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tile.entityId != actionEntityId) resetTileAction();
  }

  @override
  Widget build(BuildContext context) {
    watchTileActions();
    final entity = ref.watch(entitiesProvider).value?[actionEntityId];
    final l10n = AppLocalizations.of(context);
    if (entity == null || entity.domain != 'climate') {
      return ColoredBox(
        color: CupertinoColors.systemGrey5.resolveFrom(context),
        child: Center(child: Text(l10n.commonUnknownEntity)),
      );
    }
    final current = finiteTileNumber(entity.attributes['current_temperature']);
    final target = finiteTileNumber(entity.attributes['temperature']);
    final minTemp = finiteTileNumber(entity.attributes['min_temp']);
    final maxTemp = finiteTileNumber(entity.attributes['max_temp']);
    final rawStep = entity.attributes['target_temp_step'];
    final step = rawStep == null ? 0.5 : finiteTileNumber(rawStep);
    final validRange =
        target != null &&
        minTemp != null &&
        maxTemp != null &&
        maxTemp > minTemp &&
        (maxTemp - minTemp).isFinite &&
        step != null &&
        step > 0 &&
        ((maxTemp - minTemp) / step).isFinite;
    final supportsTemperature = tileServiceAvailable(
      entity,
      'set_temperature',
      feature: 1,
    );
    final canSetTemperature = !tileActionBusy && supportsTemperature;
    final unit = entity.attributes['temperature_unit'] is String
        ? entity.attributes['temperature_unit'] as String
        : '°';

    return ColoredBox(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      child: Padding(
        padding: Insets.tile,
        child: TileContentViewport(
          builder: (context, availableHeight) => Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                entity.friendlyName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.tileTitle,
              ),
              SizedBox(
                height: max(
                  84.0,
                  availableHeight - MediaQuery.textScalerOf(context).scale(60),
                ),
                child: validRange && supportsTemperature
                    ? Semantics(
                        key: ValueKey('climate-dial-$actionEntityId'),
                        label: l10n.entityControlTemperature,
                        child: _RadialDial(
                          key: ValueKey(
                            '$actionEntityId-$tileActionGeneration',
                          ),
                          value: target.clamp(minTemp, maxTemp),
                          min: minTemp,
                          max: maxTemp,
                          step: step,
                          unit: unit,
                          currentTemperature: current,
                          onCommitted: canSetTemperature
                              ? (value) => executeTileAction(
                                  'climate',
                                  'set_temperature',
                                  feature: 1,
                                  serviceData: {'temperature': value},
                                )
                              : null,
                        ),
                      )
                    : Center(
                        child: Text(
                          target == null ? entity.state : '$target$unit',
                        ),
                      ),
              ),
              Text(
                entity.attributes['hvac_action'] is String
                    ? entity.attributes['hvac_action'] as String
                    : entity.state,
                style: AppText.tileSubtitle.copyWith(
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              TileActionFeedback(
                entityId: actionEntityId,
                error: tileActionError,
                busy: tileActionBusy,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RadialDial extends StatefulWidget {
  const _RadialDial({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.unit,
    this.onCommitted,
    this.currentTemperature,
  });
  final double value;
  final double min;
  final double max;
  final double step;
  final String unit;
  final double? currentTemperature;
  final ValueChanged<double>? onCommitted;
  @override
  State<_RadialDial> createState() => _RadialDialState();
}

class _RadialDialState extends State<_RadialDial> {
  late double _value = widget.value;
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant _RadialDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value ||
        oldWidget.min != widget.min ||
        oldWidget.max != widget.max ||
        oldWidget.step != widget.step ||
        widget.onCommitted == null) {
      _dragging = false;
      _value = widget.value;
    }
  }

  double _snap(double raw) {
    final bounded = raw.clamp(widget.min, widget.max);
    return double.parse(
      (widget.min +
              ((bounded - widget.min) / widget.step).round() * widget.step)
          .clamp(widget.min, widget.max)
          .toStringAsFixed(6),
    );
  }

  void _handlePan(Offset localPosition, Size size) {
    if (!mounted ||
        widget.onCommitted == null ||
        !localPosition.dx.isFinite ||
        !localPosition.dy.isFinite ||
        !size.width.isFinite ||
        !size.height.isFinite) {
      return;
    }
    final vector = localPosition - Offset(size.width / 2, size.height / 2);
    var angle = (atan2(vector.dy, vector.dx) + pi / 2) % (2 * pi);
    if (angle < 0) angle += 2 * pi;
    final fraction = (angle / (2 * pi)).clamp(0.0, 1.0);
    setState(() {
      _dragging = true;
      _value = _snap(widget.min + fraction * (widget.max - widget.min));
    });
  }

  void _commit() {
    if (!mounted || !_dragging || widget.onCommitted == null) return;
    final selected = _value;
    setState(() {
      _dragging = false;
      _value = widget.value;
    });
    if ((selected - widget.value).abs() > 0.0001) widget.onCommitted!(selected);
  }

  @override
  Widget build(BuildContext context) {
    final fraction = ((_value - widget.min) / (widget.max - widget.min)).clamp(
      0.0,
      1.0,
    );
    final enabled = widget.onCommitted != null;
    return Semantics(
      value: '$_value${widget.unit}',
      increasedValue: enabled && _value < widget.max
          ? '${_snap(_value + widget.step)}${widget.unit}'
          : null,
      decreasedValue: enabled && _value > widget.min
          ? '${_snap(_value - widget.step)}${widget.unit}'
          : null,
      onIncrease: enabled && _value < widget.max
          ? () => widget.onCommitted!(_snap(_value + widget.step))
          : null,
      onDecrease: enabled && _value > widget.min
          ? () => widget.onCommitted!(_snap(_value - widget.step))
          : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: enabled
                ? (details) => _handlePan(details.localPosition, size)
                : null,
            onPanUpdate: enabled
                ? (details) => _handlePan(details.localPosition, size)
                : null,
            onPanEnd: enabled ? (_) => _commit() : null,
            onPanCancel: enabled
                ? () => setState(() {
                    _dragging = false;
                    _value = widget.value;
                  })
                : null,
            child: CustomPaint(
              painter: _DialPainter(
                fraction: fraction,
                color: categoryColorForDomain(context, 'climate'),
                trackColor: CupertinoColors.systemGrey4.resolveFrom(context),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${double.parse(_value.toStringAsFixed(6))}${widget.unit}',
                      style: AppText.title3,
                    ),
                    if (widget.currentTemperature != null)
                      Text(
                        AppLocalizations.of(context).climateCurrentReading(
                          '${widget.currentTemperature!.toStringAsFixed(1)}${widget.unit}',
                        ),
                        style: AppText.caption2.copyWith(
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.fraction,
    required this.color,
    required this.trackColor,
  });

  final double fraction;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide / 2) - 6;
    if (!radius.isFinite || radius <= 0) return;
    final backgroundPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    final foregroundPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, backgroundPaint);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2,
      2 * pi * fraction,
      false,
      foregroundPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _DialPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.color != color ||
      // Without this the track keeps its old colour across a light/dark
      // switch, since nothing else about the painter changes.
      oldDelegate.trackColor != trackColor;
}
