import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/typography.dart';
import '../data/local_notification_platform.dart';

class LocalNotificationPlatformCard extends StatelessWidget {
  const LocalNotificationPlatformCard({
    super.key,
    required this.status,
    required this.onRequestPermission,
    required this.onOpenNotificationSettings,
    required this.onOpenPowerSettings,
  });

  final AndroidNotificationStatus status;
  final VoidCallback? onRequestPermission;
  final VoidCallback? onOpenNotificationSettings;
  final VoidCallback? onOpenPowerSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = switch (status.permission) {
      AndroidNotificationPermission.unsupported =>
        l10n.localNotificationsAndroidUnsupported,
      AndroidNotificationPermission.notRequested =>
        l10n.localNotificationsAndroidNotRequested,
      AndroidNotificationPermission.denied =>
        l10n.localNotificationsAndroidDenied,
      AndroidNotificationPermission.granted when !status.channelEnabled =>
        l10n.localNotificationsAndroidChannelDisabled,
      AndroidNotificationPermission.granted =>
        l10n.localNotificationsAndroidGranted,
    };
    final showRequest =
        status.permission == AndroidNotificationPermission.notRequested;
    final showSettings =
        status.permission == AndroidNotificationPermission.denied ||
        status.permission == AndroidNotificationPermission.granted &&
            !status.channelEnabled;
    return Semantics(
      container: true,
      label: '${l10n.localNotificationsAndroidTitle}. $state',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface.resolveFrom(context),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.localNotificationsAndroidTitle,
                style: AppText.headline,
              ),
              const SizedBox(height: 6),
              Text(state, style: AppText.body),
              const SizedBox(height: 6),
              Text(
                l10n.localNotificationsAndroidForegroundOnly,
                style: AppText.footnote,
              ),
              if (showRequest)
                CupertinoButton(
                  key: const ValueKey('notification-permission-request'),
                  minimumSize: const Size(48, 48),
                  onPressed: onRequestPermission,
                  child: Text(l10n.localNotificationsAndroidEnable),
                ),
              if (showSettings)
                CupertinoButton(
                  key: const ValueKey('notification-settings-open'),
                  minimumSize: const Size(48, 48),
                  onPressed: onOpenNotificationSettings,
                  child: Text(l10n.localNotificationsAndroidSettings),
                ),
              CupertinoButton(
                key: const ValueKey('notification-power-open'),
                minimumSize: const Size(48, 48),
                onPressed: onOpenPowerSettings,
                child: Text(l10n.localNotificationsAndroidPower),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
