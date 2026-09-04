import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/category_colors.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';

class ClimateTile extends ConsumerWidget {
  const ClimateTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity = ref.watch(entitiesProvider).value?[tile.entityId];
    if (entity == null) {
      return ColoredBox(
        color: CupertinoColors.systemGrey5.resolveFrom(context),
        child: Center(
          child: Text(AppLocalizations.of(context).commonUnknownEntity),
        ),
      );
    }

    final current = (entity.attributes['current_temperature'] as num?)
        ?.toDouble();
    final target = (entity.attributes['temperature'] as num?)?.toDouble();
    final minTemp = (entity.attributes['min_temp'] as num?)?.toDouble() ?? 7;
    final maxTemp = (entity.attributes['max_temp'] as num?)?.toDouble() ?? 35;

    return ColoredBox(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      child: Padding(
        padding: Insets.tile,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              entity.friendlyName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.tileTitle,
            ),
            Expanded(
              child: target == null
                  ? Center(child: Text(entity.state))
                  : _RadialDial(
                      value: target,
                      min: minTemp,
                      max: maxTemp,
                      currentTemperature: current,
                      onChanged: (value) => ref
                          .read(haRestClientProvider)
                          ?.callService(
                            'climate',
                            'set_temperature',
                            entityId: entity.entityId,
                            serviceData: {'temperature': value},
                          ),
                    ),
            ),
            Text(
              (entity.attributes['hvac_action'] as String?) ?? entity.state,
              style: TextStyle(
                fontSize: AppText.tileSubtitle.fontSize,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadialDial extends StatefulWidget {
  const _RadialDial({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.currentTemperature,
  });

  final double value;
  final double min;
  final double max;
  final double? currentTemperature;
  final ValueChanged<double> onChanged;

  @override
  State<_RadialDial> createState() => _RadialDialState();
}

class _RadialDialState extends State<_RadialDial> {
  late double _value = widget.value;

  @override
  void didUpdateWidget(covariant _RadialDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _value = widget.value;
  }

  void _handlePan(Offset localPosition, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final vector = localPosition - center;
    var angle = (atan2(vector.dy, vector.dx) + pi / 2) % (2 * pi);
    if (angle < 0) angle += 2 * pi;
    final fraction = (angle / (2 * pi)).clamp(0.0, 1.0);
    final newValue = widget.min + fraction * (widget.max - widget.min);
    setState(() => _value = double.parse(newValue.toStringAsFixed(1)));
    widget.onChanged(_value);
  }

  @override
  Widget build(BuildContext context) {
    final fraction = ((_value - widget.min) / (widget.max - widget.min)).clamp(
      0.0,
      1.0,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onPanUpdate: (details) => _handlePan(details.localPosition, size),
          child: CustomPaint(
            painter: _DialPainter(
              fraction: fraction,
              color: categoryColorForDomain(context, 'climate'),
              // A CustomPainter gets no BuildContext, so a dynamic colour
              // handed to Paint.color can never resolve itself — it has to
              // be resolved here and passed in already-concrete.
              trackColor: CupertinoColors.systemGrey4.resolveFrom(context),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${_value.toStringAsFixed(1)}°', style: AppText.title3),
                  if (widget.currentTemperature != null)
                    Text(
                      'now ${widget.currentTemperature!.toStringAsFixed(1)}°',
                      style: TextStyle(
                        fontSize: AppText.caption2.fontSize,
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
