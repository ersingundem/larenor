import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/category_colors.dart';
import '../../../ha_client/data/models/ha_entity.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../providers/dashboard_providers.dart';
import '../widgets/more_info_sheet.dart';
import 'entity_icons.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/radii.dart';
import '../../../../shared/theme/icon_sizes.dart';

/// Domains where a plain tap is safe to treat as "toggle this".
///
/// Deliberately excludes locks and covers: `lock`/`cover` don't accept
/// `turn_on`/`turn_off` anyway, and an accidental tap unlocking a door on
/// a wall-mounted panel is exactly the kind of thing that shouldn't be one
/// stray finger away. Those open the detail sheet instead.
bool tapTogglesEntity(HaEntity entity) =>
    entity.isToggleable || entity.domain == 'scene';

/// An Apple Home-style accessory tile: a rounded card that carries its own
/// on/off state in its colouring, toggles on tap, and opens a context menu
/// on long press.
class HomeAccessoryTile extends ConsumerWidget {
  const HomeAccessoryTile({super.key, required this.entity});

  final HaEntity entity;

  static const _glyphSize = 34.0;

  /// The height this tile needs at the current text scale.
  ///
  /// The grid used to pin a fixed aspect ratio, which meant the cell
  /// stopped fitting its own contents around 1.8x system text size. The
  /// glyph circle is fixed, but both text lines grow, so the height has
  /// to be derived rather than assumed.
  static double heightFor(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    const lineFactor = 1.35;
    final title = scaler.scale(AppText.tileTitle.fontSize!) * lineFactor;
    final subtitle = scaler.scale(AppText.tileSubtitle.fontSize!) * lineFactor;
    return Gap.md * 2 + _glyphSize + Gap.xxs + title + subtitle;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categoryColor = categoryColorForDomain(
      context,
      entity.domain,
      deviceClass: entity.attributes['device_class'] as String?,
    );
    final isOn = entity.isOn;

    final background = isOn
        ? categoryColor.withValues(alpha: 0.18)
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final glyphBackground = isOn
        ? categoryColor
        : CupertinoColors.systemFill.resolveFrom(context);
    final glyphColor = isOn
        ? CupertinoColors.white
        : CupertinoColors.secondaryLabel.resolveFrom(context);

    return GestureDetector(
      onTap: () {
        if (tapTogglesEntity(entity)) {
          ref.read(entitiesProvider.notifier).toggle(entity);
        } else {
          showEntityMoreInfo(context, entity.entityId);
        }
      },
      onLongPress: () => _showActions(context, ref),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: Radii.brLarge,
        ),
        child: Padding(
          padding: Insets.tile,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: _glyphSize,
                height: _glyphSize,
                decoration: BoxDecoration(
                  color: glyphBackground,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  iconForEntity(entity),
                  size: IconSizes.body,
                  color: glyphColor,
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entity.friendlyName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileTitle.copyWith(
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  const SizedBox(height: Gap.xxs),
                  Text(
                    _stateLabel(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.tileSubtitle.fontSize,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Prefers a reading (temperature, humidity, …) over the raw state
  /// string, the way Apple Home shows "21°" rather than "on".
  String _stateLabel(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final unit = entity.attributes['unit_of_measurement'] as String?;
    if (unit != null && double.tryParse(entity.state) != null) {
      return '${entity.state}$unit';
    }
    if (entity.domain == 'light' || entity.domain == 'switch') {
      return entity.isOn ? l10n.moreInfoOn : l10n.commonOff;
    }
    return entity.state;
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final layout = ref.read(dashboardLayoutProvider).value;
    final isFavourite =
        layout?.favoriteEntityIds.contains(entity.entityId) ?? false;

    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(entity.friendlyName),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              showEntityMoreInfo(context, entity.entityId);
            },
            child: Text(l10n.homeActionMoreInfo),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              ref
                  .read(dashboardLayoutProvider.notifier)
                  .toggleFavorite(entity.entityId);
            },
            child: Text(
              isFavourite
                  ? l10n.homeActionRemoveFavourite
                  : l10n.homeActionAddFavourite,
            ),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(sheetContext).pop();
              ref
                  .read(dashboardLayoutProvider.notifier)
                  .hideEntity(entity.entityId);
            },
            child: Text(l10n.homeActionHide),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
  }
}
