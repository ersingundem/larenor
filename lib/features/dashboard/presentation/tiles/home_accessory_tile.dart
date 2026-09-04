import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
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
import '../../../../shared/theme/icon_sizes.dart';
import 'entity_state_label.dart';

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
class HomeAccessoryTile extends ConsumerStatefulWidget {
  const HomeAccessoryTile({super.key, required this.entity, this.roomId});

  final HaEntity entity;

  /// The room this tile is being shown in, when it's in one. Favourites
  /// aren't, so removing from a room isn't offered there.
  final String? roomId;

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
  ConsumerState<HomeAccessoryTile> createState() => _HomeAccessoryTileState();
}

class _HomeAccessoryTileState extends ConsumerState<HomeAccessoryTile> {
  HaEntity get entity => widget.entity;
  String? get roomId => widget.roomId;
  bool _busy = false;
  static const _glyphSize = HomeAccessoryTile._glyphSize;

  Future<void> _activate() async {
    if (_busy) return;
    if (!tapTogglesEntity(entity) ||
        {'unavailable', 'unknown'}.contains(entity.state)) {
      showEntityMoreInfo(context, entity.entityId);
      return;
    }
    setState(() => _busy = true);
    HapticFeedback.selectionClick();
    try {
      await ref.read(entitiesProvider.notifier).toggle(entity);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      final l10n = AppLocalizations.of(context);
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(entity.friendlyName),
          content: Text(l10n.homeActionFailed),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.commonOk),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoryColor = categoryColorForDomain(
      context,
      entity.domain,
      deviceClass: entity.attributes['device_class'] as String?,
    );
    final isOn = entity.isOn;

    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final background = isOn
        ? (dark ? categoryColor.withValues(alpha: 0.25) : CupertinoColors.white)
        : CupertinoColors.secondarySystemGroupedBackground
              .resolveFrom(context)
              .withValues(alpha: dark ? 0.72 : 0.60);
    final glyphBackground = isOn
        ? categoryColor
        : CupertinoColors.systemFill.resolveFrom(context);
    final glyphColor = isOn
        ? CupertinoColors.white
        : CupertinoColors.secondaryLabel.resolveFrom(context);

    return Semantics(
      button: true,
      label: '${entity.friendlyName}, ${entityStateLabel(context, entity)}',
      onTap: _activate,
      child: GestureDetector(
        onTap: _activate,
        onLongPress: () => _showActions(context, ref),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isOn
                  ? categoryColor.withValues(alpha: 0.18)
                  : CupertinoColors.white.withValues(alpha: dark ? 0.04 : 0.35),
            ),
            boxShadow: isOn
                ? [
                    BoxShadow(
                      color: categoryColor.withValues(alpha: 0.07),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Padding(
            padding: Insets.tile,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
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
                    if (_busy)
                      const CupertinoActivityIndicator(radius: 8)
                    else if (isOn)
                      Icon(
                        CupertinoIcons.circle_fill,
                        size: 6,
                        color: categoryColor,
                      ),
                  ],
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
                      entityStateLabel(context, entity),
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
      ),
    );
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
          if (roomId != null)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.of(sheetContext).pop();
                ref
                    .read(dashboardLayoutProvider.notifier)
                    .removeEntityFromRoom(roomId!, entity.entityId);
              },
              child: Text(l10n.roomRemoveDevice),
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
