import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../settings/data/app_service.dart';
import '../../../../shared/widgets/brand_icon.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/theme/icon_sizes.dart';

/// Shared visual shell for the 11 external-service summary tiles — same
/// icon/title header, a "not connected" placeholder when the service
/// isn't configured, and up to a few compact content lines otherwise.
/// Unlike the HA-entity tiles these aren't per-entity, they're per-service
/// (one tile references the app-wide service connection directly), so
/// there's no entity lookup here — just a tap-through to that service's
/// own screen.
class ServiceTileShell extends StatelessWidget {
  const ServiceTileShell({
    super.key,
    required this.icon,
    required this.title,
    required this.connected,
    required this.onTap,
    required this.lines,
    this.service,
  });

  final IconData icon;
  final String title;
  final bool connected;
  final VoidCallback onTap;
  final List<String> lines;

  /// When set and a real vendored logo exists for it, that logo is shown
  /// via [BrandIcon] in the header instead of the generic [icon].
  final AppService? service;

  @override
  Widget build(BuildContext context) {
    final service = this.service;
    return GestureDetector(
      onTap: onTap,
      child: ColoredBox(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        child: Padding(
          padding: Insets.tile,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (service != null && hasBrandIcon(service))
                    BrandIcon(service: service, size: IconSizes.body)
                  else
                    Icon(
                      icon,
                      size: 18,
                      color: CupertinoTheme.of(context).primaryColor,
                    ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.tileTitle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.sm),
              if (!connected)
                Text(
                  AppLocalizations.of(context).commonNotConnected,
                  style: TextStyle(
                    fontSize: AppText.tileSubtitle.fontSize,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                )
              else
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.tileSubtitle.fontSize,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
