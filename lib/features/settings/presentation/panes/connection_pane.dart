import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/icon_badge.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../auth/presentation/connect_screen.dart';
import '../../../auth/providers/auth_providers.dart';
import 'settings_nav_row.dart';

class ConnectionPane extends ConsumerWidget {
  const ConnectionPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final config = ref.watch(connectionConfigProvider).value;

    return SettingsPaneScaffold(
      title: l10n.settingsCategoryConnection,
      children: [
        SettingsSection(
          children: [
            SettingsActionTile(
              leading: const IconBadge(
                icon: CupertinoIcons.house_fill,
                color: CupertinoColors.systemBlue,
              ),
              title: Text(l10n.settingsHaServer),
              additionalInfo: Text(config?.baseUrl ?? l10n.commonNotConnected),
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute(
                  builder: (_) => ConnectScreen(initialUrl: config?.baseUrl),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
