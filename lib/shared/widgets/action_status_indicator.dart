import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../features/health/data/action_receipt.dart';
import '../../features/health/data/integration_health.dart';
import '../../features/health/providers/action_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../theme/typography.dart';

String actionStatusLabel(AppLocalizations l10n, ActionReceipt receipt) =>
    switch (receipt.status) {
      ActionStatus.sending => l10n.actionSending,
      ActionStatus.accepted =>
        receipt.completedAt == null
            ? l10n.actionAwaitingState
            : l10n.actionAccepted,
      ActionStatus.confirmed => l10n.actionStateObserved,
      ActionStatus.failed => l10n.actionFailed,
      ActionStatus.unknown => l10n.actionUnknown,
    };

String actionErrorLabel(AppLocalizations l10n, Object error) => switch (error) {
  ActionExecutionException(:final receipt) => actionStatusLabel(l10n, receipt),
  ActionInProgressException() => l10n.actionAlreadyPending,
  _ => l10n.actionFailed,
};

/// Shows only the latest request receipt, with an explicit time. It never
/// infers connectivity or a physical device result from server acceptance.
class ActionStatusIndicator extends ConsumerWidget {
  const ActionStatusIndicator({super.key, required this.entityId});

  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final receipt = ref.watch(
      actionReceiptsProvider.select(
        (value) => value.value
            ?.where(
              (item) =>
                  item.key.integration == IntegrationId.ha &&
                  item.key.target == entityId,
            )
            .firstOrNull,
      ),
    );
    if (receipt == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final label = actionStatusLabel(l10n, receipt);
    final color = switch (receipt.status) {
      ActionStatus.failed => CupertinoColors.systemRed,
      ActionStatus.unknown => CupertinoColors.systemOrange,
      ActionStatus.confirmed => CupertinoColors.systemGreen,
      _ => CupertinoColors.secondaryLabel,
    };
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          key: ValueKey('action-status-$entityId'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(color: color.resolveFrom(context))),
            const SizedBox(height: 3),
            Text(
              l10n.actionLastRequest(
                DateFormat.yMd(l10n.localeName)
                    .add_Hms()
                    .format(receipt.createdAt.toLocal()),
              ),
              style: AppText.caption1.copyWith(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
