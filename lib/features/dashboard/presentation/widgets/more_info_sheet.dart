import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../ha_client/data/models/ha_entity.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../providers/dashboard_providers.dart';
import '../../../../shared/theme/typography.dart';

const _hiddenAttributeKeys = {'friendly_name', 'icon'};

/// Shared "more info" popup used by every entity-backed tile — full state,
/// a brightness slider for lights, and a raw attribute dump. Dedicated tile
/// types (media player, climate, weather, camera) get their own bespoke
/// controls instead of relying on this generic sheet.
Future<void> showEntityMoreInfo(BuildContext context, String entityId) {
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (context) => _MoreInfoSheet(entityId: entityId),
  );
}

class _MoreInfoSheet extends ConsumerWidget {
  const _MoreInfoSheet({required this.entityId});

  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entity = ref.watch(entitiesProvider).value?[entityId];
    final favorites =
        ref.watch(dashboardLayoutProvider).value?.favoriteEntityIds ?? const [];
    final isFavorite = favorites.contains(entityId);

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => DecoratedBox(
        decoration: BoxDecoration(
          color: CupertinoColors.systemBackground.resolveFrom(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: entity == null
            ? Center(
                child: Text(
                  AppLocalizations.of(context).moreInfoEntityNotFound,
                ),
              )
            : ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemGrey3.resolveFrom(context),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entity.friendlyName,
                          style: CupertinoTheme.of(context)
                              .textTheme
                              .navLargeTitleTextStyle,
                        ),
                      ),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => ref
                            .read(dashboardLayoutProvider.notifier)
                            .toggleFavorite(entity.entityId),
                        child: Icon(
                          isFavorite
                              ? CupertinoIcons.star_fill
                              : CupertinoIcons.star,
                          color: CupertinoColors.systemYellow,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    entity.state,
                    style: TextStyle(
                      fontSize: AppText.body.fontSize,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (entity.isToggleable)
                    CupertinoListSection.insetGrouped(
                      children: [
                        CupertinoListTile(
                          title: Text(AppLocalizations.of(context).moreInfoOn),
                          trailing: CupertinoSwitch(
                            value: entity.isOn,
                            onChanged: (_) => ref
                                .read(entitiesProvider.notifier)
                                .toggle(entity),
                          ),
                        ),
                      ],
                    ),
                  if (entity.domain == 'light' &&
                      entity.attributes['brightness'] is num)
                    _BrightnessSlider(entity: entity),
                  const SizedBox(height: 8),
                  CupertinoListSection.insetGrouped(
                    header: Text(
                      AppLocalizations.of(context).moreInfoDetailsHeader,
                    ),
                    children: [
                      CupertinoListTile(
                        title: Text(
                          AppLocalizations.of(context).moreInfoEntityId,
                        ),
                        additionalInfo: Text(entity.entityId),
                      ),
                      if (entity.lastChanged != null)
                        CupertinoListTile(
                          title: Text(
                            AppLocalizations.of(context).moreInfoLastChanged,
                          ),
                          additionalInfo: Text(
                            entity.lastChanged!.toLocal().toString().split(
                              '.',
                            )[0],
                          ),
                        ),
                      for (final attribute in entity.attributes.entries)
                        if (!_hiddenAttributeKeys.contains(attribute.key))
                          CupertinoListTile(
                            title: Text(attribute.key),
                            additionalInfo: Text('${attribute.value}'),
                          ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _BrightnessSlider extends ConsumerWidget {
  const _BrightnessSlider({required this.entity});

  final HaEntity entity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brightness = (entity.attributes['brightness'] as num).toDouble();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Icon(CupertinoIcons.sun_max, size: 20),
          Expanded(
            child: CupertinoSlider(
              value: (brightness / 255).clamp(0.0, 1.0),
              onChanged: (value) {
                ref
                    .read(haRestClientProvider)
                    ?.callService(
                      'light',
                      'turn_on',
                      entityId: entity.entityId,
                      serviceData: {'brightness_pct': (value * 100).round()},
                    );
              },
            ),
          ),
        ],
      ),
    );
  }
}
