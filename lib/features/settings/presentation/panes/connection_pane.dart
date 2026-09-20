import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/icon_badge.dart';
import '../../../../shared/widgets/integration_health_status.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../auth/presentation/connect_screen.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../health/data/integration_health.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import 'settings_nav_row.dart';

class ConnectionPane extends ConsumerStatefulWidget {
  const ConnectionPane({super.key});

  @override
  ConsumerState<ConnectionPane> createState() => _ConnectionPaneState();
}

class _ConnectionPaneState extends MediaSessionState<ConnectionPane> {
  bool _current(int generation, Object? config) {
    final reading = ref.read(connectionConfigProvider);
    return sessionCurrent(generation) &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent == true &&
        !reading.isLoading &&
        !reading.hasError &&
        identical(reading.value, config);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final reading = ref.watch(connectionConfigProvider);
    final config = reading.value;
    final generation = sessionGeneration;
    final active = _current(generation, config);

    return SettingsPaneScaffold(
      title: l10n.settingsCategoryConnection,
      children: [
        SettingsSection(
          header: Semantics(
            key: const ValueKey('connection-settings-header'),
            header: true,
            child: Text(l10n.settingsCategoryConnection),
          ),
          children: [
            SettingsActionTile(
              buttonKey: const ValueKey('connection-home-assistant-action'),
              leading: const IconBadge(
                icon: CupertinoIcons.house_fill,
                color: CupertinoColors.systemBlue,
              ),
              title: Text(l10n.settingsHaServer),
              additionalInfo: Text(config?.baseUrl ?? l10n.commonNotConnected),
              onTap: active
                  ? () {
                      if (!_current(generation, config)) return;
                      Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) =>
                              ConnectScreen(initialUrl: config?.baseUrl),
                        ),
                      );
                    }
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: reading.isLoading
                  ? Text(l10n.commonLoading)
                  : reading.hasError
                  ? Text(l10n.commonError)
                  : IntegrationHealthStatus(
                      id: IntegrationId.ha,
                      configured: config != null,
                    ),
            ),
          ],
        ),
      ],
    );
  }
}
