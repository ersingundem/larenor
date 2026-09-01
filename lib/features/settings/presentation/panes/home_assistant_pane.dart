import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../admin/presentation/areas_screen.dart';
import '../../../admin/presentation/automations_screen.dart';
import '../../../admin/presentation/cameras_screen.dart';
import '../../../admin/presentation/devices_screen.dart';
import '../../../admin/presentation/entities_screen.dart';
import '../../../admin/presentation/integrations_screen.dart';
import 'settings_nav_row.dart';

class HomeAssistantPane extends StatelessWidget {
  const HomeAssistantPane({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return SettingsPaneScaffold(
      title: l10n.settingsCategoryHomeAssistant,
      children: [
        CupertinoListSection.insetGrouped(
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
