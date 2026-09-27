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
    required this.backgroundFailure,
    required this.backgroundOutcomeUnknown,
    required this.onEnableBackground,
    required this.onMaintainBackground,
    required this.onDisableBackground,
  });

  final AndroidNotificationStatus status;
  final VoidCallback? onRequestPermission;
  final VoidCallback? onOpenNotificationSettings;
  final VoidCallback? onOpenPowerSettings;
  final String? backgroundFailure;
  final bool backgroundOutcomeUnknown;
  final VoidCallback? onEnableBackground;
  final VoidCallback? onMaintainBackground;
  final VoidCallback? onDisableBackground;

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
    final background = status.backgroundDelivery;
    final backgroundText = backgroundOutcomeUnknown
        ? l10n.localNotificationsBackgroundOutcomeUnknown
        : backgroundFailure != null
        ? l10n.localNotificationsBackgroundError
        : status.recoveryRequired
        ? l10n.localNotificationsBackgroundRecovery
        : background?.state == AndroidBackgroundDeliveryState.pending
        ? l10n.localNotificationsBackgroundPending
        : background?.state == AndroidBackgroundDeliveryState.active
        ? '${l10n.localNotificationsBackgroundActive} '
              '${l10n.localNotificationsBackgroundExpiry(background!.expiresAt.toLocal().toIso8601String())}'
        : l10n.localNotificationsAndroidForegroundOnly;
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
              Semantics(
                liveRegion: backgroundOutcomeUnknown || status.recoveryRequired,
                child: Text(
                  backgroundText,
                  style: AppText.footnote.copyWith(
                    color:
                        backgroundOutcomeUnknown ||
                            status.recoveryRequired ||
                            backgroundFailure != null
                        ? CupertinoColors.systemRed.resolveFrom(context)
                        : null,
                  ),
                ),
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
              if (status.canPresent && background == null)
                CupertinoButton.filled(
                  key: const ValueKey('notification-background-enable'),
                  minimumSize: const Size(48, 48),
                  onPressed: onEnableBackground,
                  child: Text(l10n.localNotificationsBackgroundEnable),
                ),
              if (background != null)
                CupertinoButton(
                  key: const ValueKey('notification-background-maintain'),
                  minimumSize: const Size(48, 48),
                  onPressed: onMaintainBackground,
                  child: Text(
                    background.state ==
                                AndroidBackgroundDeliveryState.pending ||
                            status.recoveryRequired ||
                            backgroundOutcomeUnknown
                        ? l10n.localNotificationsBackgroundRecover
                        : l10n.localNotificationsBackgroundRenew,
                  ),
                ),
              if (background != null)
                CupertinoButton(
                  key: const ValueKey('notification-background-disable'),
                  minimumSize: const Size(48, 48),
                  onPressed: onDisableBackground,
                  child: Text(l10n.localNotificationsBackgroundDisable),
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
