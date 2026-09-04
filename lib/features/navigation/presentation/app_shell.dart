import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/larenor_brand.dart';
import '../../auth/presentation/connect_screen.dart';
import '../../auth/providers/auth_providers.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import 'app_shell_actions.dart';

/// Branch navigators retain each root's selection, drilldown and scroll state.
class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.navigationShell,
    required this.location,
  });
  final StatefulNavigationShell navigationShell;
  final Uri location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionConfigProvider);
    if (connection.isLoading && !connection.hasValue) {
      return const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    if (connection.hasError) {
      return CupertinoPageScaffold(
        child: Center(
          child: Text(AppLocalizations.of(context).settingsGateStorageError),
        ),
      );
    }
    if (connection.value == null) return const ConnectScreen();
    final l10n = AppLocalizations.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final roots = <({String label, IconData icon})>[
      (label: l10n.navigationHome, icon: CupertinoIcons.house_fill),
      (label: l10n.navigationMedia, icon: CupertinoIcons.play_rectangle_fill),
      (label: l10n.navigationRoutines, icon: CupertinoIcons.sparkles),
      (label: l10n.navigationSystem, icon: CupertinoIcons.square_stack_3d_up),
    ];

    void select(int index) => navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
    return AppShellScope(
      hasSidebar: wide,
      child: CupertinoPageScaffold(
        backgroundColor: AppColors.canvas.resolveFrom(context),
        child: Row(
          children: [
            if (wide)
              Container(
                width: 238,
                decoration: BoxDecoration(
                  color: AppColors.navigation.resolveFrom(context),
                  border: Border(
                    right: BorderSide(
                      color: CupertinoColors.separator.resolveFrom(context),
                      width: 0.5,
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
                      for (var i = 0; i < roots.length; i++)
                        _NavigationRow(
                          label: roots[i].label,
                          icon: roots[i].icon,
                          selected: navigationShell.currentIndex == i,
                          onPressed: () => select(i),
                        ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          children: [
                            if (navigationShell.currentIndex == 0) ...[
                              _NavigationRow(
                                label: l10n.todayTitle,
                                icon: CupertinoIcons.calendar,
                                selected: location.path == '/today',
                                onPressed: () => context.go('/today'),
                              ),
                              _NavigationRow(
                                label: l10n.intercomTitle,
                                icon: CupertinoIcons.bell,
                                selected: location.path == '/intercom',
                                onPressed: () => context.go('/intercom'),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  26,
                                  0,
                                  20,
                                  8,
                                ),
                                child: Text(
                                  l10n.homeRooms,
                                  style: AppText.footnote,
                                ),
                              ),
                              for (final room
                                  in ref
                                          .watch(dashboardLayoutProvider)
                                          .value
                                          ?.rooms ??
                                      [])
                                _NavigationRow(
                                  label: room.name,
                                  icon: CupertinoIcons.square_grid_2x2,
                                  selected:
                                      location.pathSegments.length == 2 &&
                                      location.pathSegments.first == 'rooms' &&
                                      location.pathSegments.last == room.id,
                                  onPressed: () => context.go(
                                    Uri(pathSegments: ['', 'rooms', room.id])
                                        .toString(),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                      _NavigationRow(
                        label: l10n.navigationSearch,
                        icon: CupertinoIcons.search,
                        onPressed: () => context.push('/search'),
                      ),
                      _NavigationRow(
                        label: l10n.settingsScreenTitle,
                        icon: CupertinoIcons.settings,
                        onPressed: () => context.push('/settings'),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: navigationShell),
                  if (!wide)
                    CupertinoTabBar(
                      currentIndex: navigationShell.currentIndex,
                      onTap: select,
                      backgroundColor: AppColors.navigation.resolveFrom(
                        context,
                      ),
                      items: [
                        for (final root in roots)
                          BottomNavigationBarItem(
                            icon: Icon(root.icon),
                            label: root.label,
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavigationRow extends StatelessWidget {
  const _NavigationRow({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
    child: Semantics(
      selected: selected,
      button: true,
      child: CupertinoButton(
        color: selected ? AppColors.surface.resolveFrom(context) : null,
        borderRadius: BorderRadius.circular(14),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onPressed: onPressed,
        child: Row(
          children: [
            Icon(icon, size: 21),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.subhead.copyWith(
                  color: CupertinoColors.label.resolveFrom(context),
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
