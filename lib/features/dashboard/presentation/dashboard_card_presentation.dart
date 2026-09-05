import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/spacing.dart';
import '../../../shared/theme/typography.dart';
import '../domain/dashboard_card_size.dart';
import 'tiles/home_accessory_tile.dart';
import 'tiles/dashboard_tile_button.dart';
import 'widgets/dashboard_grid_delegate.dart';

DashboardGridSpan cardSizeSpan(DashboardCardSize size) => switch (size) {
  DashboardCardSize.small => const DashboardGridSpan(1, 1),
  DashboardCardSize.medium => const DashboardGridSpan(2, 1),
  DashboardCardSize.large => const DashboardGridSpan(2, 2),
};

String cardSizeLabel(AppLocalizations l10n, DashboardCardSize? size) =>
    switch (size) {
      DashboardCardSize.small => l10n.dashboardCardSmall,
      DashboardCardSize.medium => l10n.dashboardCardMedium,
      DashboardCardSize.large => l10n.dashboardCardLarge,
      null => l10n.dashboardCardDefault,
    };

/// Service summaries have a header and up to three text lines. A small card
/// still has to fit those lines at the user's Dynamic Type size.
double dashboardServiceRowExtent(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  return math.max(
    HomeAccessoryTile.heightFor(context),
    DashboardTileButton.focusInset * 2 +
        Gap.md * 2 +
        Gap.sm +
        math.max(34, scaler.scale(AppText.tileTitle.fontSize!) * 1.35) +
        3 * (scaler.scale(AppText.tileSubtitle.fontSize!) * 1.35 + 2),
  );
}
