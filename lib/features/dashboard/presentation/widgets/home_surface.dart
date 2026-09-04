import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/larenor_brand.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../ha_client/data/models/ha_entity.dart';
import '../../domain/dashboard_room.dart';

/// Home shares the adaptive page palette with media and settings.
class HomeWallpaper extends StatelessWidget {
  const HomeWallpaper({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => AppSurface(child: child);
}

class HomeOverview extends StatelessWidget {
  const HomeOverview({super.key, required this.entities});
  final List<HaEntity> entities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final lights = entities.where((e) => e.domain == 'light' && e.isOn).length;
    final unavailable = entities
        .where((e) => e.state == 'unavailable' || e.state == 'unknown')
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (MediaQuery.sizeOf(context).width < 1000) ...[
            const LarenorBrand(compact: true),
            const SizedBox(height: 24),
          ],
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _StatusPill(
                icon: CupertinoIcons.square_grid_2x2_fill,
                text: l10n.homeAccessoriesCount(entities.length),
                color: CupertinoColors.systemBlue.resolveFrom(context),
              ),
              if (lights > 0)
                _StatusPill(
                  icon: CupertinoIcons.lightbulb_fill,
                  text: l10n.homeSummaryLightsOn(lights),
                  color: CupertinoColors.systemOrange.resolveFrom(context),
                ),
              if (unavailable > 0)
                _StatusPill(
                  icon: CupertinoIcons.exclamationmark_circle,
                  text: l10n.homeUnavailableCount(unavailable),
                  color: CupertinoColors.systemRed.resolveFrom(context),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.text,
    required this.color,
  });
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground
          .resolveFrom(context)
          .withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 7),
        Flexible(child: Text(text, style: AppText.footnote)),
      ],
    ),
  );
}

class HomeSidebar extends StatelessWidget {
  const HomeSidebar({
    super.key,
    required this.rooms,
    required this.selectedRoom,
    required this.onSelectRoom,
    required this.onAddRoom,
    required this.onSettings,
    this.onMedia,
  });
  final List<DashboardRoom> rooms;
  final String? selectedRoom;
  final ValueChanged<String?> onSelectRoom;
  final VoidCallback onAddRoom;
  final VoidCallback onSettings;
  final VoidCallback? onMedia;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      width: 238,
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground
            .resolveFrom(context)
            .withValues(alpha: 0.35),
        border: Border(
          right: BorderSide(
            color: CupertinoColors.separator
                .resolveFrom(context)
                .withValues(alpha: 0.12),
          ),
        ),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 28, 20, 28),
              child: LarenorBrand(compact: true),
            ),
            _SidebarRow(
              icon: CupertinoIcons.house_fill,
              label: l10n.homeOverview,
              selected: selectedRoom == null,
              onTap: () => onSelectRoom(null),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 30, 20, 10),
              child: Text(
                l10n.homeRooms,
                style: AppText.footnote.copyWith(
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final room in rooms)
                    _SidebarRow(
                      icon: CupertinoIcons.square_grid_2x2,
                      label: room.name,
                      selected: selectedRoom == room.id,
                      onTap: () => onSelectRoom(room.id),
                    ),
                  _SidebarRow(
                    icon: CupertinoIcons.add_circled,
                    label: l10n.dashboardAddRoom,
                    onTap: onAddRoom,
                  ),
                ],
              ),
            ),
            if (onMedia != null)
              _SidebarRow(
                icon: CupertinoIcons.play_rectangle,
                label: l10n.homeCategoryMedia,
                onTap: onMedia!,
              ),
            _SidebarRow(
              icon: CupertinoIcons.settings,
              label: l10n.settingsScreenTitle,
              onTap: onSettings,
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
    child: CupertinoButton(
      color: selected
          ? CupertinoColors.systemBackground
                .resolveFrom(context)
                .withValues(alpha: 0.8)
          : null,
      borderRadius: BorderRadius.circular(14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      onPressed: onTap,
      child: Row(
        children: [
          Icon(
            icon,
            size: 21,
            color: selected
                ? const Color(0xFFD99043)
                : CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.subhead.copyWith(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
