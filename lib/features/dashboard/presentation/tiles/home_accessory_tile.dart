import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/category_colors.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../ha_client/data/models/ha_entity.dart';
import '../../../wellbeing/providers/wellbeing_providers.dart';
import '../../../wellbeing/providers/wellbeing_privacy_providers.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../domain/dashboard_card_size.dart';
import '../dashboard_card_presentation.dart';
import '../dashboard_edit_guard.dart';
import '../../providers/dashboard_providers.dart';
import '../../providers/dashboard_live_providers.dart';
import '../widgets/more_info_sheet.dart';
import 'entity_icons.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/icon_sizes.dart';
import 'entity_state_label.dart';
import 'dashboard_tile_button.dart';

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
  const HomeAccessoryTile({
    super.key,
    required this.entity,
    this.roomId,
    this.title,
    this.enableContextMenu = true,
  });

  final HaEntity entity;
  final String? title;

  /// Saved widget cards use the dashboard's widget menu instead.
  final bool enableContextMenu;

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
    return DashboardTileButton.focusInset * 2 +
        Gap.md * 2 +
        _glyphSize +
        Gap.xxs +
        title +
        subtitle;
  }

  @override
  ConsumerState<HomeAccessoryTile> createState() => _HomeAccessoryTileState();
}

class _HomeAccessoryTileState extends DashboardEditState<HomeAccessoryTile> {
  HaEntity get entity => widget.entity;
  String get title => widget.title ?? entity.friendlyName;
  String? get roomId => widget.roomId;
  bool _busy = false;
  bool _menuOpen = false;
  Route<dynamic>? _menuRoute;

  bool get _roomCurrent {
    if (!mounted) return false;
    if (!isPublicHaEntity(
      ref.read(wellbeingPrivateEntityIdsProvider),
      entity.entityId,
    )) {
      return false;
    }
    if (roomId == null) return true;
    final room = ref
        .read(dashboardLayoutProvider)
        .value
        ?.rooms
        .where((room) => room.id == roomId)
        .firstOrNull;
    return room != null && roomMatchesCurrentServer(ref, room);
  }

  @override
  void invalidateDashboardInteraction() {
    final route = _menuRoute;
    _menuRoute = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  @override
  void didUpdateWidget(HomeAccessoryTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entity.entityId != widget.entity.entityId ||
        oldWidget.roomId != roomId) {
      interactionGeneration++;
      invalidateDashboardInteraction();
    }
  }

  Future<String?> _menu(WidgetBuilder builder) async {
    final route = CupertinoModalPopupRoute<String>(builder: builder);
    _menuRoute = route;
    try {
      return await Navigator.of(context).push<String>(route);
    } finally {
      if (identical(_menuRoute, route)) _menuRoute = null;
    }
  }

  static const _glyphSize = HomeAccessoryTile._glyphSize;

  Future<void> _activate() async {
    final generation = interactionGeneration;
    if (_busy ||
        _menuOpen ||
        !interactionCurrent(generation) ||
        !_roomCurrent) {
      return;
    }
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
      if (!mounted || !interactionCurrent(generation) || !_roomCurrent) return;
      setState(() => _busy = false);
      final l10n = AppLocalizations.of(context);
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(l10n.homeActionFailed),
          actions: [
            CupertinoDialogAction(
              onPressed: () => closeDashboardModal(dialogContext),
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
    final privacy = ref.watch(wellbeingPrivateEntityIdsProvider);
    ref.listen(wellbeingPrivateEntityIdsProvider, (previous, next) {
      if (!isPublicHaEntity(next, entity.entityId)) {
        interactionGeneration++;
        invalidateDashboardInteraction();
      }
    });
    if (!isPublicHaEntity(privacy, entity.entityId)) {
      return const SizedBox.shrink();
    }
    if (roomId != null) {
      final room = ref.watch(
        dashboardLayoutProvider.select(
          (layout) => layout.value?.rooms
              .where((room) => room.id == roomId)
              .firstOrNull,
        ),
      );
      if (room?.areaBinding != null) ref.watch(connectionConfigProvider);
    }
    watchDashboardAccount();
    final enabled = foreground && _roomCurrent;
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

    return DashboardTileButton(
      label: '$title, ${entityStateLabel(context, entity)}',
      onPressed: enabled ? dashboardAction(_activate) : null,
      onLongPress: enabled && widget.enableContextMenu
          ? dashboardAction(_showActions)
          : null,
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
                    title,
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
    );
  }

  Future<void> _showActions() async {
    final generation = interactionGeneration;
    if (_menuOpen ||
        _busy ||
        !interactionCurrent(generation) ||
        !_roomCurrent) {
      return;
    }
    _menuOpen = true;
    final l10n = AppLocalizations.of(context);
    final target = entity.entityId;
    final name = title;
    final layout = ref.read(dashboardLayoutProvider).value;
    final isFavourite = layout?.favoriteEntityIds.contains(target) ?? false;
    try {
      final action = await _menu(
        (sheetContext) => CupertinoActionSheet(
          title: Text(name),
          actions: [
            for (final entry in <String, String>{
              'more': l10n.homeActionMoreInfo,
              'size': l10n.dashboardCardSize,
              'favorite': isFavourite
                  ? l10n.homeActionRemoveFavourite
                  : l10n.homeActionAddFavourite,
              if (roomId != null) 'remove': l10n.roomRemoveDevice,
            }.entries)
              CupertinoActionSheetAction(
                isDestructiveAction: entry.key == 'remove',
                onPressed: () {
                  if (sheetContext.mounted &&
                      ModalRoute.of(sheetContext)?.isCurrent == true) {
                    closeDashboardModal(sheetContext, entry.key);
                  }
                },
                child: Text(entry.value),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => closeDashboardModal(sheetContext),
            child: Text(l10n.commonCancel),
          ),
        ),
      );
      if (!mounted ||
          !interactionCurrent(generation) ||
          !_roomCurrent ||
          action == null) {
        return;
      }
      switch (action) {
        case 'more':
          showEntityMoreInfo(context, target);
        case 'favorite':
          await ref
              .read(dashboardLayoutProvider.notifier)
              .toggleFavorite(target);
        case 'remove':
          await ref
              .read(dashboardLayoutProvider.notifier)
              .removeEntityFromRoom(roomId!, target);
        case 'size':
          final choice = await _menu(
            (sheetContext) => CupertinoActionSheet(
              title: Text(l10n.dashboardCardSize),
              actions: [
                for (final size in <DashboardCardSize?>[
                  ...DashboardCardSize.values,
                  null,
                ])
                  CupertinoActionSheetAction(
                    onPressed: () {
                      if (sheetContext.mounted &&
                          ModalRoute.of(sheetContext)?.isCurrent == true) {
                        closeDashboardModal(
                          sheetContext,
                          size?.name ?? 'default',
                        );
                      }
                    },
                    child: Text(cardSizeLabel(l10n, size)),
                  ),
              ],
              cancelButton: CupertinoActionSheetAction(
                onPressed: () => closeDashboardModal(sheetContext),
                child: Text(l10n.commonCancel),
              ),
            ),
          );
          if (choice == null ||
              !interactionCurrent(generation) ||
              !_roomCurrent) {
            return;
          }
          await ref
              .read(dashboardLayoutProvider.notifier)
              .setEntityCardSize(
                target,
                choice == 'default'
                    ? null
                    : DashboardCardSize.values.byName(choice),
              );
      }
    } catch (_) {
      if (mounted && interactionCurrent(generation)) {
        await showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            content: Text(l10n.dashboardEditFailed),
            actions: [
              CupertinoDialogAction(
                onPressed: () => closeDashboardModal(dialogContext),
                child: Text(l10n.commonOk),
              ),
            ],
          ),
        );
      }
    } finally {
      _menuOpen = false;
    }
  }
}

/// Keeps live changes local to this accessory rather than its parent grid.
class LiveHomeAccessoryTile extends ConsumerWidget {
  const LiveHomeAccessoryTile({super.key, required this.entityId, this.roomId});

  final String entityId;
  final String? roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => HomeAccessoryTile(
    entity: ref.watch(dashboardEntityProvider(entityId)),
    roomId: roomId,
  );
}
