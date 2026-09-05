import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/category_colors.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/theme/icon_sizes.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/tile_config.dart';
import '../dashboard_edit_guard.dart';

class WeatherForecastDay {
  const WeatherForecastDay({
    required this.date,
    this.condition,
    this.temperature,
  });
  final DateTime date;
  final String? condition;
  final num? temperature;
}

/// Daily forecast responses preserve their supplied calendar date. Parsing
/// an explicit offset into the tablet's timezone can move a day backwards.
List<WeatherForecastDay> parseWeatherForecast(
  Object? response,
  String entityId,
) {
  if (response is! Map) throw const FormatException('Invalid forecast');
  final services = response['service_response'];
  final entry = services is Map ? services[entityId] : null;
  final days = entry is Map ? entry['forecast'] : null;
  if (days is! List || days.length > 1000) {
    throw const FormatException('Invalid forecast');
  }
  return List.unmodifiable(
    days.take(5).map((day) {
      if (day is! Map) throw const FormatException('Invalid forecast');
      final iso = day['datetime'];
      final condition = day['condition'];
      final temperature = day['temperature'];
      if (iso is! String ||
          iso.length < 10 ||
          DateTime.tryParse(iso) == null ||
          (condition != null && condition is! String) ||
          (temperature != null &&
              (temperature is! num || !temperature.isFinite))) {
        throw const FormatException('Invalid forecast');
      }
      final date = DateTime.tryParse(iso.substring(0, 10));
      if (date == null) throw const FormatException('Invalid forecast');
      return WeatherForecastDay(
        date: date,
        condition: condition as String?,
        temperature: temperature as num?,
      );
    }),
  );
}

/// One account-bound read shared by visible cards for the same entity.
/// Keep an unfinished read alive through a brief hide/resume to avoid overlap.
/// https://www.home-assistant.io/integrations/weather/#list-of-actions
final weatherForecastProvider = FutureProvider.autoDispose
    .family<List<WeatherForecastDay>?, String>((ref, entityId) async {
      final config = ref.watch(connectionConfigProvider);
      if (config.isLoading || config.hasError || config.value == null) {
        return null;
      }
      final rest = ref.watch(haRestClientProvider);
      if (rest == null) return null;
      final pending = ref.keepAlive();
      try {
        final result = await rest.postJson(
          '/api/services/weather/get_forecasts?return_response',
          {'entity_id': entityId, 'type': 'daily'},
        );
        return parseWeatherForecast(result, entityId);
      } finally {
        pending.close();
      }
    }, retry: (_, _) => null);

class WeatherTile extends ConsumerStatefulWidget {
  const WeatherTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  ConsumerState<WeatherTile> createState() => _WeatherTileState();
}

class _WeatherTileState extends DashboardEditState<WeatherTile> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final active = foreground && TickerMode.valuesOf(context).enabled;
    final config = active ? ref.watch(connectionConfigProvider) : null;
    watchDashboardAccount();
    final states = active ? ref.watch(entitiesProvider) : null;
    final ready =
        config != null &&
        !config.isLoading &&
        !config.hasError &&
        config.value != null;
    final entity =
        !ready || states == null || states.isLoading || states.hasError
        ? null
        : states.value?[widget.tile.entityId];
    final forecast = active && entity?.domain == 'weather'
        ? ref.watch(weatherForecastProvider(entity!.entityId))
        : null;
    final data = forecast == null || forecast.isLoading || forecast.hasError
        ? null
        : forecast.value;
    final rawTemperature = entity?.attributes['temperature'];
    final temperature = rawTemperature is num && rawTemperature.isFinite
        ? rawTemperature
        : null;
    final unit = entity?.attributes['temperature_unit'];
    final temperatureUnit = unit is String ? unit : '°';
    final name = entity?.attributes['friendly_name'];
    return ColoredBox(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: Insets.tile,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (entity == null)
                Text(
                  !active
                      ? l10n.commonNoData
                      : config?.hasError == true || states?.hasError == true
                      ? l10n.healthReadError
                      : !ready
                      ? l10n.navigationUnconfigured
                      : l10n.commonUnknownEntity,
                )
              else ...[
                Row(
                  children: [
                    Icon(
                      _iconForCondition(entity.state),
                      size: IconSizes.control,
                      color: categoryColorForDomain(context, 'weather'),
                    ),
                    const SizedBox(width: 8),
                    if (temperature != null)
                      Flexible(
                        child: Text(
                          '$temperature$temperatureUnit',
                          style: AppText.title2,
                        ),
                      ),
                  ],
                ),
                Text(
                  widget.tile.title ??
                      (name is String ? name : entity.entityId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.tileSubtitle,
                ),
                const SizedBox(height: 8),
                if (forecast?.isLoading == true)
                  const Center(child: CupertinoActivityIndicator())
                else if (forecast?.hasError == true) ...[
                  Text(l10n.healthReadError, style: AppText.caption2),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: dashboardAction(() {
                      if (mounted &&
                          foreground &&
                          TickerMode.valuesOf(context).enabled &&
                          widget.tile.entityId == entity.entityId) {
                        ref.invalidate(
                          weatherForecastProvider(entity.entityId),
                        );
                      }
                    }),
                    child: Text(l10n.commonRetry),
                  ),
                ] else if (data == null || data.isEmpty)
                  Text(l10n.commonNoData, style: AppText.caption2)
                else
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final day in data)
                          Padding(
                            padding: const EdgeInsets.only(right: 14),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  DateFormat.E(
                                    Localizations.localeOf(context).toString(),
                                  ).format(day.date),
                                  style: AppText.caption2,
                                ),
                                Icon(
                                  _iconForCondition(day.condition),
                                  size: 18,
                                ),
                                if (day.temperature != null)
                                  Text(
                                    '${day.temperature}$temperatureUnit',
                                    style: AppText.caption2,
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconForCondition(String? condition) => switch (condition) {
    'sunny' || 'clear-night' => CupertinoIcons.sun_max,
    'partlycloudy' => CupertinoIcons.cloud_sun,
    'rainy' || 'pouring' => CupertinoIcons.cloud_rain,
    'snowy' => CupertinoIcons.snow,
    'lightning' || 'lightning-rainy' => CupertinoIcons.bolt_fill,
    _ => CupertinoIcons.cloud,
  };
}
