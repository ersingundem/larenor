import 'package:flutter/cupertino.dart';

import '../../../settings/data/app_service.dart';
import '../../../../shared/widgets/brand_icon.dart';

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
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (service != null && hasBrandIcon(service))
                    BrandIcon(service: service, size: 18)
                  else
                    Icon(
                      icon,
                      size: 18,
                      color: CupertinoTheme.of(context).primaryColor,
                    ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (!connected)
                Text(
                  'Not connected',
                  style: TextStyle(
                    fontSize: 11,
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
                        fontSize: 11,
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
