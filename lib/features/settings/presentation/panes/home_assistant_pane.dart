import 'package:flutter/cupertino.dart';

import '../../../../shared/widgets/settings_section.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../admin/presentation/areas_screen.dart';
import '../../../admin/presentation/automations_screen.dart';
import '../../../admin/presentation/cameras_screen.dart';
import '../../../admin/presentation/devices_screen.dart';
import '../../../admin/presentation/entities_screen.dart';
import '../../../admin/presentation/integrations_screen.dart';
import 'settings_nav_row.dart';
import '../../../ha_tools/presentation/ha_actions_screen.dart';
import '../../../ha_tools/presentation/ha_tools_screen.dart';
import '../../../ha_tools/presentation/ha_frontend_screen.dart';

class HomeAssistantPane extends StatelessWidget {
  const HomeAssistantPane({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return SettingsPaneScaffold(
      title: l10n.settingsCategoryHomeAssistant,
      children: [
        SettingsSection(
          footer: Text(l10n.haFrontendHint),
          children: [
            SettingsNavRow(
              icon: CupertinoIcons.bolt_fill,
              color: CupertinoColors.systemOrange,
              title: l10n.haActions,
              builder: (_) => const HaActionsScreen(),
            ),
            SettingsNavRow(
              icon: CupertinoIcons.chevron_left_slash_chevron_right,
              color: CupertinoColors.systemIndigo,
              title: l10n.haTools,
              builder: (_) => const HaToolsScreen(),
            ),
            SettingsNavRow(
              icon: CupertinoIcons.globe,
              color: CupertinoColors.systemBlue,
              title: l10n.haFrontend,
              builder: (_) => const HaFrontendScreen(),
            ),
          ],
        ),
        SettingsSection(
          children: [
            SettingsNavRow(
              icon: CupertinoIcons.cube_box,
              color: CupertinoColors.systemBlue,
              title: l10n.settingsIntegrations,
              builder: (_) => const IntegrationsScreen(),
            ),
            SettingsNavRow(
              icon: CupertinoIcons.device_laptop,
              color: CupertinoColors.systemGrey,
              title: l10n.settingsDevices,
              builder: (_) => const DevicesScreen(),
            ),
            SettingsNavRow(
              icon: CupertinoIcons.square_grid_2x2,
              color: CupertinoColors.systemGreen,
              title: l10n.settingsAreas,
              builder: (_) => const AreasScreen(),
            ),
            SettingsNavRow(
              icon: CupertinoIcons.list_bullet,
              color: CupertinoColors.systemIndigo,
              title: l10n.settingsEntities,
              builder: (_) => const EntitiesScreen(),
            ),
            SettingsNavRow(
              icon: CupertinoIcons.bolt,
              color: CupertinoColors.systemOrange,
              title: l10n.settingsAutomations,
              builder: (_) => const AutomationsScreen(),
            ),
            SettingsNavRow(
              icon: CupertinoIcons.videocam,
              color: CupertinoColors.systemPurple,
              title: l10n.settingsCameras,
              builder: (_) => const CamerasScreen(),
            ),
          ],
        ),
      ],
    );
  }
}
