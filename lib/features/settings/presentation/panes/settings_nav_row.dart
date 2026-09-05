import 'package:flutter/cupertino.dart';

import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/brand_icon.dart';
import '../../../../shared/widgets/icon_badge.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../data/app_service.dart';

/// A settings row that pushes another screen. In the split layout the push
/// lands in the detail pane's own [Navigator], so drilling into (say)
/// Integrations keeps the master list visible beside it, exactly like iPad
/// Settings.
class SettingsNavRow extends StatelessWidget {
  const SettingsNavRow({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.builder,
    this.service,
  });

  final IconData icon;
  final Color color;
  final String title;
  final WidgetBuilder builder;

  /// When set and a real vendored logo exists for it, that logo is shown
  /// via [BrandIcon] instead of the generic [icon]/[color] pair.
  final AppService? service;

  @override
  Widget build(BuildContext context) {
    final service = this.service;
    return SettingsActionTile(
      leading: service != null && hasBrandIcon(service)
          ? BrandIcon(service: service)
          : IconBadge(icon: icon, color: color),
      title: Text(title),
      // `title` auto-populates the pushed screen's back button, so it
      // reads the section's name rather than a generic "Back".
      onTap: () =>
          Navigator.of(context)
              .push(CupertinoPageRoute(title: title, builder: builder)),
    );
  }
}

/// Shared chrome for every settings pane, so a pane renders identically
/// whether it's the detail half of the split layout or a full-screen push
/// on a narrow display.
class SettingsPaneScaffold extends StatelessWidget {
  const SettingsPaneScaffold({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(largeTitle: Text(title)),
          SliverSafeArea(
            top: false,
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 8),
                ...children,
                const SizedBox(height: 32),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
