import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/settings_section.dart';

import '../../../shared/widgets/app_page_scaffold.dart';

import '../../../core/breakpoints.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/icon_badge.dart';
import 'panes/about_pane.dart';
import 'panes/connection_pane.dart';
import 'panes/display_pane.dart';
import 'panes/home_assistant_pane.dart';
import 'panes/integrations_pane.dart';
import 'panes/security_pane.dart';
import 'settings_file_dialog.dart';
import '../../backup/presentation/backup_screen.dart';
import '../../intercom/presentation/intercom_settings_screen.dart';

/// The top-level settings categories, in the order they appear down the
/// master list.
enum SettingsCategory {
  connection,
  display,
  security,
  homeAssistant,
  intercom,
  integrations,
  backup,
  about,
}

/// Settings as an iPad-style split view: the categories stay listed down
/// the left while the selected one fills the right half. On a display too
/// narrow for two useful panes it falls back to the plain iOS behaviour of
/// pushing each category full-screen.
class SettingsSplitScreen extends StatefulWidget {
  const SettingsSplitScreen({super.key, this.runFileDialog});

  final SettingsFileDialogRunner? runFileDialog;

  @override
  State<SettingsSplitScreen> createState() => _SettingsSplitScreenState();
}

class _SettingsSplitScreenState extends State<SettingsSplitScreen> {
  SettingsCategory _selected = SettingsCategory.connection;

  /// Rebuilt whenever the selection changes so the detail pane's nested
  /// navigator resets to that category's root — picking a new category
  /// shouldn't leave you inside the previous one's sub-screen.
  Key _detailKey = UniqueKey();

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
              selected: _selected,
              onSelect: (category) => setState(() {
                _selected = category;
                _detailKey = UniqueKey();
              }),
            ),
          ),
          Container(
            width: 0.5,
            color: CupertinoColors.separator.resolveFrom(context),
          ),
          Expanded(
            child: Navigator(
              key: _detailKey,
              onGenerateRoute: (settings) => CupertinoPageRoute<void>(
                settings: settings,
                builder: (_) =>
                    paneFor(_selected, runFileDialog: widget.runFileDialog),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNarrow(BuildContext context) {
    return _MasterList(
      selected: null,
      onSelect: (category) => Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (_) =>
              paneFor(category, runFileDialog: widget.runFileDialog),
        ),
      ),
    );
  }
}

Widget paneFor(
  SettingsCategory category, {
  SettingsFileDialogRunner? runFileDialog,
}) {
  switch (category) {
    case SettingsCategory.connection:
      return const ConnectionPane();
    case SettingsCategory.display:
      return const DisplayPane();
    case SettingsCategory.security:
      return const SecurityPane();
    case SettingsCategory.homeAssistant:
      return const HomeAssistantPane();
    case SettingsCategory.intercom:
      return const IntercomSettingsScreen();
    case SettingsCategory.integrations:
      return const IntegrationsPane();
    case SettingsCategory.backup:
      return BackupScreen(runFileDialog: runFileDialog);
    case SettingsCategory.about:
      return const AboutPane();
  }
}

class _MasterList extends StatelessWidget {
  const _MasterList({required this.selected, required this.onSelect});

  /// `null` in the narrow layout, where nothing stays selected because the
  /// detail screen covers the list entirely.
  final SettingsCategory? selected;
  final ValueChanged<SettingsCategory> onSelect;

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
                        child: CupertinoListTile(
                          leading: IconBadge(icon: icon, color: color),
                          title: Text(title),
                          trailing: const CupertinoListTileChevron(),
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
