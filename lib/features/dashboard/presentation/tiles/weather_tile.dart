import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/category_colors.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/theme/icon_sizes.dart';

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
      return ColoredBox(
        color: CupertinoColors.systemGrey5.resolveFrom(context),
        child: Center(
          child: Text(AppLocalizations.of(context).commonUnknownEntity),
        ),
      );
    }

    final temperature = entity.attributes['temperature'];

    return ColoredBox(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      child: Padding(
        padding: Insets.tile,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _iconForCondition(entity.state),
                  size: IconSizes.control,
                  color: categoryColorForDomain(context, 'weather'),
                ),
                const SizedBox(width: 8),
                if (temperature != null)
                  Text('$temperature°', style: AppText.title2),
              ],
            ),
            Text(
              entity.friendlyName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.tileSubtitle,
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
                                context,
                                (day as Map<String, dynamic>)['datetime']
                                    as String?,
                              ),
                              style: AppText.caption2,
                            ),
                            Icon(
                              _iconForCondition(day['condition'] as String?),
                              size: 16,
                            ),
                            Text(
                              '${day['temperature']}°',
                              style: AppText.caption2,
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

  String _shortDay(BuildContext context, String? iso) {
    if (iso == null) return '';
    final date = DateTime.tryParse(iso);
    if (date == null) return '';
    final locale = Localizations.localeOf(context).toString();
    return DateFormat.E(locale).format(date);
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
