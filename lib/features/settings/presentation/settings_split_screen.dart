import 'package:flutter/cupertino.dart';

import '../../../core/breakpoints.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../backup/presentation/backup_screen.dart';
import '../../remote_access/presentation/remote_profiles_screen.dart';
import '../../intercom/presentation/intercom_settings_screen.dart';
import '../../mesh_center/presentation/mesh_center_route.dart';
import '../../room_comfort/presentation/room_comfort_route.dart';
import '../../server/presentation/server_connection_screen.dart';
import '../../server/tablet_fleet/presentation/server_tablet_fleet_screen.dart';
import 'panes/about_pane.dart';
import 'panes/connection_pane.dart';
import 'panes/display_pane.dart';
import 'panes/home_assistant_pane.dart';
import 'panes/integrations_pane.dart';
import 'panes/security_pane.dart';
import 'settings_file_dialog.dart';

/// The top-level settings categories, in the order they appear down the
/// master list.
enum SettingsCategory {
  connection,
  server,
  tabletFleet,
  remoteAccess,
  roomComfort,
  display,
  security,
  homeAssistant,
  intercom,
  integrations,
  meshCenter,
  backup,
  about,
}

/// Settings as an iPad-style split view: the categories stay listed down
/// the left while the selected one fills the right half. On a display too
/// narrow for two useful panes it falls back to the plain iOS behaviour of
/// pushing each category full-screen.
class SettingsSplitScreen extends StatefulWidget {
  const SettingsSplitScreen({
    super.key,
    this.runFileDialog,
    this.onExit,
    this.backupGateCurrent,
    this.remoteGateCurrent,
    this.meshGateCurrent,
    this.comfortGateCurrent,
    this.tabletFleetGateCurrent,
  });

  final SettingsFileDialogRunner? runFileDialog;
  final VoidCallback? onExit;
  final bool Function()? backupGateCurrent;
  final bool Function()? remoteGateCurrent;
  final bool Function()? meshGateCurrent;
  final bool Function()? comfortGateCurrent;
  final bool Function()? tabletFleetGateCurrent;

  @override
  State<SettingsSplitScreen> createState() => _SettingsSplitScreenState();
}

class _SettingsSplitScreenState extends State<SettingsSplitScreen> {
  SettingsCategory _selected = SettingsCategory.connection;
  late GlobalKey<NavigatorState> _detailNavigatorKey;
  late _DetailNavigatorObserver _detailNavigatorObserver;
  bool _detailCanPop = false;
  int _detailGeneration = 0;

  /// Rebuilt whenever the selection changes so the detail pane's nested
  /// navigator resets to that category's root — picking a new category
  /// shouldn't leave you inside the previous one's sub-screen.
  @override
  void initState() {
    super.initState();
    _resetDetailNavigator();
  }

  void _resetDetailNavigator() {
    final generation = ++_detailGeneration;
    _detailCanPop = false;
    _detailNavigatorKey = GlobalKey<NavigatorState>();
    _detailNavigatorObserver = _DetailNavigatorObserver(
      () => _scheduleDetailPopState(generation),
    );
  }

  void _scheduleDetailPopState(int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _detailGeneration) return;
      final canPop = _detailNavigatorKey.currentState?.canPop() ?? false;
      if (canPop == _detailCanPop) return;
      setState(() => _detailCanPop = canPop);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= kSplitViewMinWidth;
        return isWide ? _buildSplit(context) : _buildNarrow(context);
      },
    );
  }

  Widget _buildSplit(BuildContext context) {
    return AppPageScaffold(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 320,
            child: _MasterList(
              onExit: widget.onExit,
              selected: _selected,
              onSelect: (category) => setState(() {
                _selected = category;
                _resetDetailNavigator();
              }),
            ),
          ),
          Container(
            width: 0.5,
            color: CupertinoColors.separator.resolveFrom(context),
          ),
          Expanded(
            // Confine the nested route's semantic barrier to the detail pane;
            // the independently interactive category list stays accessible.
            child: NavigatorPopHandler<void>(
              enabled: _detailCanPop,
              onPopWithResult: (_) =>
                  _detailNavigatorKey.currentState?.maybePop(),
              child: Semantics(
                container: true,
                child: Navigator(
                  key: _detailNavigatorKey,
                  observers: [_detailNavigatorObserver],
                  onGenerateRoute: (settings) => CupertinoPageRoute<void>(
                    settings: settings,
                    builder: (_) => paneFor(
                      _selected,
                      runFileDialog: widget.runFileDialog,
                      backupGateCurrent: widget.backupGateCurrent,
                      remoteGateCurrent: widget.remoteGateCurrent,
                      meshGateCurrent: widget.meshGateCurrent,
                      comfortGateCurrent: widget.comfortGateCurrent,
                      tabletFleetGateCurrent: widget.tabletFleetGateCurrent,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNarrow(BuildContext context) {
    return _MasterList(
      onExit: widget.onExit,
      selected: null,
      onSelect: (category) => Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (_) => paneFor(
            category,
            runFileDialog: widget.runFileDialog,
            backupGateCurrent: widget.backupGateCurrent,
            remoteGateCurrent: widget.remoteGateCurrent,
            meshGateCurrent: widget.meshGateCurrent,
            comfortGateCurrent: widget.comfortGateCurrent,
            tabletFleetGateCurrent: widget.tabletFleetGateCurrent,
          ),
        ),
      ),
    );
  }
}

class _DetailNavigatorObserver extends NavigatorObserver {
  _DetailNavigatorObserver(this.onChanged);

  final VoidCallback onChanged;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onChanged();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onChanged();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onChanged();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    onChanged();
  }
}

Widget paneFor(
  SettingsCategory category, {
  SettingsFileDialogRunner? runFileDialog,
  bool Function()? backupGateCurrent,
  bool Function()? remoteGateCurrent,
  bool Function()? meshGateCurrent,
  bool Function()? comfortGateCurrent,
  bool Function()? tabletFleetGateCurrent,
}) {
  switch (category) {
    case SettingsCategory.connection:
      return const ConnectionPane();
    case SettingsCategory.remoteAccess:
      return RemoteProfilesScreen(
        gateCurrent: remoteGateCurrent ?? () => false,
      );
    case SettingsCategory.roomComfort:
      return RoomComfortRoute(gateCurrent: comfortGateCurrent ?? () => false);
    case SettingsCategory.server:
      return ServerConnectionScreen(adminGateCurrent: tabletFleetGateCurrent);
    case SettingsCategory.tabletFleet:
      return ServerTabletFleetScreen(
        gateCurrent: tabletFleetGateCurrent ?? () => false,
      );
    case SettingsCategory.display:
      return DisplayPane(runFileDialog: runFileDialog);
    case SettingsCategory.security:
      return const SecurityPane();
    case SettingsCategory.homeAssistant:
      return const HomeAssistantPane();
    case SettingsCategory.intercom:
      return const IntercomSettingsScreen();
    case SettingsCategory.integrations:
      return const IntegrationsPane();
    case SettingsCategory.meshCenter:
      return MeshCenterRoute(gateCurrent: meshGateCurrent ?? () => false);
    case SettingsCategory.backup:
      return BackupScreen(
        runFileDialog: runFileDialog,
        gateCurrent: backupGateCurrent,
      );
    case SettingsCategory.about:
      return const AboutPane();
  }
}

class _MasterList extends StatelessWidget {
  const _MasterList({
    required this.selected,
    required this.onSelect,
    this.onExit,
  });

  /// `null` in the narrow layout, where nothing stays selected because the
  /// detail screen covers the list entirely.
  final SettingsCategory? selected;
  final ValueChanged<SettingsCategory> onSelect;
  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final entries = <(SettingsCategory, IconData, Color, String)>[
      (
        SettingsCategory.connection,
        CupertinoIcons.house_fill,
        CupertinoColors.systemBlue,
        l10n.settingsCategoryConnection,
      ),
      (
        SettingsCategory.server,
        CupertinoIcons.cloud,
        CupertinoColors.systemIndigo,
        l10n.serverTitle,
      ),
      (
        SettingsCategory.tabletFleet,
        CupertinoIcons.device_phone_portrait,
        CupertinoColors.systemPurple,
        l10n.serverTabletFleetTitle,
      ),
      (
        SettingsCategory.remoteAccess,
        CupertinoIcons.desktopcomputer,
        CupertinoColors.systemTeal,
        l10n.remoteAccessTitle,
      ),
      (
        SettingsCategory.roomComfort,
        CupertinoIcons.thermometer,
        CupertinoColors.systemGreen,
        Localizations.localeOf(context).languageCode == 'tr'
            ? 'Oda konforu'
            : 'Room comfort',
      ),
      (
        SettingsCategory.display,
        CupertinoIcons.brightness,
        CupertinoColors.systemYellow,
        l10n.settingsCategoryDisplay,
      ),
      (
        SettingsCategory.security,
        CupertinoIcons.lock_fill,
        CupertinoColors.systemRed,
        l10n.settingsCategorySecurity,
      ),
      (
        SettingsCategory.homeAssistant,
        CupertinoIcons.cube_box,
        CupertinoColors.systemIndigo,
        l10n.settingsCategoryHomeAssistant,
      ),
      (
        SettingsCategory.integrations,
        CupertinoIcons.slider_horizontal_3,
        CupertinoColors.systemGrey,
        l10n.settingsCategoryIntegrations,
      ),
      (
        SettingsCategory.meshCenter,
        CupertinoIcons.antenna_radiowaves_left_right,
        CupertinoColors.systemGreen,
        l10n.meshCenterTitle,
      ),
      (
        SettingsCategory.intercom,
        CupertinoIcons.bell_fill,
        CupertinoColors.systemOrange,
        l10n.intercomTitle,
      ),
      (
        SettingsCategory.backup,
        CupertinoIcons.archivebox_fill,
        CupertinoColors.systemOrange,
        l10n.backupTitle,
      ),
      (
        SettingsCategory.about,
        CupertinoIcons.info,
        CupertinoColors.systemTeal,
        l10n.settingsCategoryAbout,
      ),
    ];

    return AppPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            leading: onExit == null
                ? null
                : CupertinoNavigationBarBackButton(onPressed: onExit),
            largeTitle: Text(l10n.settingsScreenTitle),
          ),
          SliverSafeArea(
            top: false,
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 8),
                SettingsSection(
                  children: [
                    for (final (category, icon, color, title) in entries)
                      Container(
                        color: category == selected
                            ? CupertinoColors.systemFill.resolveFrom(context)
                            : null,
                        child: SettingsActionTile(
                          leading: IconBadge(icon: icon, color: color),
                          title: Text(title),
                          selected: selected == null
                              ? null
                              : category == selected,
                          onTap: () => onSelect(category),
                        ),
                      ),
                  ],
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
