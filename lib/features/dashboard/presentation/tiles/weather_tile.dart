import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';

class WeatherTile extends ConsumerStatefulWidget {
  const WeatherTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  ConsumerState<WeatherTile> createState() => _WeatherTileState();
}

class _WeatherTileState extends ConsumerState<WeatherTile> {
  List<dynamic>? _forecast;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadForecast();
  }

  Future<void> _loadForecast() async {
    final entityId = widget.tile.entityId;
    final rest = ref.read(haRestClientProvider);
    if (rest == null || entityId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final result = await rest.postJson(
        '/api/services/weather/get_forecasts?return_response',
        {'entity_id': entityId, 'type': 'daily'},
      );
      final serviceResponse =
          (result as Map<String, dynamic>?)?['service_response']
              as Map<String, dynamic>?;
      final forecast =
          (serviceResponse?[entityId] as Map<String, dynamic>?)?['forecast']
              as List<dynamic>?;
      if (mounted) {
        setState(() {
          _forecast = forecast;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entity = ref.watch(entitiesProvider).value?[widget.tile.entityId];
    if (entity == null) {
      return const ColoredBox(
        color: CupertinoColors.systemGrey5,
        child: Center(child: Text('Unknown entity')),
      );
    }

    final temperature = entity.attributes['temperature'];

    return ColoredBox(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _iconForCondition(entity.state),
                  size: 28,
                  color: CupertinoTheme.of(context).primaryColor,
                ),
                const SizedBox(width: 8),
                if (temperature != null)
                  Text(
                    '$temperature°',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
            Text(
              entity.friendlyName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Center(child: CupertinoActivityIndicator())
            else if (_forecast != null)
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final day in _forecast!.take(5))
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _shortDay(
                                (day as Map<String, dynamic>)['datetime']
                                    as String?,
                              ),
                              style: const TextStyle(fontSize: 10),
                            ),
                            Icon(
                              _iconForCondition(day['condition'] as String?),
                              size: 16,
                            ),
                            Text(
                              '${day['temperature']}°',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _shortDay(String? iso) {
    if (iso == null) return '';
    final date = DateTime.tryParse(iso);
    if (date == null) return '';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[date.weekday - 1];
  }

  IconData _iconForCondition(String? condition) {
    switch (condition) {
      case 'sunny':
      case 'clear-night':
        return CupertinoIcons.sun_max;
      case 'partlycloudy':
        return CupertinoIcons.cloud_sun;
      case 'cloudy':
        return CupertinoIcons.cloud;
      case 'rainy':
      case 'pouring':
        return CupertinoIcons.cloud_rain;
      case 'snowy':
        return CupertinoIcons.snow;
      case 'lightning':
      case 'lightning-rainy':
        return CupertinoIcons.bolt_fill;
      default:
        return CupertinoIcons.cloud;
    }
  }
}
