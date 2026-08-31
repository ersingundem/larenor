import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/category_colors.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';

class ClimateTile extends ConsumerWidget {
  const ClimateTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity = ref.watch(entitiesProvider).value?[tile.entityId];
    if (entity == null) {
      return const ColoredBox(
        color: CupertinoColors.systemGrey5,
        child: Center(child: Text('Unknown entity')),
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
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              entity.friendlyName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
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
                fontSize: 11,
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
              color: categoryColorForDomain('climate'),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_value.toStringAsFixed(1)}°',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (widget.currentTemperature != null)
                    Text(
                      'now ${widget.currentTemperature!.toStringAsFixed(1)}°',
                      style: TextStyle(
                        fontSize: 10,
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
  _DialPainter({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide / 2) - 6;
    final backgroundPaint = Paint()
      ..color = CupertinoColors.systemGrey4
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
      oldDelegate.fraction != fraction || oldDelegate.color != color;
}
