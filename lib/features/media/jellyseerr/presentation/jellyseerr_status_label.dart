import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../data/models/jellyseerr_request_item.dart';
import '../data/models/jellyseerr_result.dart';

/// Localized label for a [JellyseerrMediaStatus], since the enum itself
/// lives in the data layer and can't call [AppLocalizations.of] directly.
String jellyseerrStatusLabel(
  BuildContext context,
  JellyseerrMediaStatus status,
) {
  final l10n = AppLocalizations.of(context);
  return switch (status) {
    JellyseerrMediaStatus.unknown => l10n.jellyseerrStatusNotRequested,
    JellyseerrMediaStatus.pending => l10n.jellyseerrStatusPending,
    JellyseerrMediaStatus.processing => l10n.jellyseerrStatusProcessing,
    JellyseerrMediaStatus.partiallyAvailable =>
      l10n.jellyseerrStatusPartiallyAvailable,
    JellyseerrMediaStatus.available => l10n.jellyseerrStatusAvailable,
    JellyseerrMediaStatus.blocklisted => l10n.mediaStatusFailed,
    JellyseerrMediaStatus.deleted => l10n.mediaStatusNotAvailable,
  };
}

/// Localized label for a [JellyseerrRequestStatus] (distinct from
/// [JellyseerrMediaStatus] — this one tracks approval, not availability).
String jellyseerrRequestStatusLabel(
  BuildContext context,
  JellyseerrRequestStatus status,
) {
  final l10n = AppLocalizations.of(context);
  return switch (status) {
    JellyseerrRequestStatus.pendingApproval =>
      l10n.jellyseerrRequestStatusPendingApproval,
    JellyseerrRequestStatus.approved => l10n.jellyseerrRequestStatusApproved,
    JellyseerrRequestStatus.declined => l10n.jellyseerrRequestStatusDeclined,
    JellyseerrRequestStatus.unknown => l10n.mediaStatusUnknown,
    JellyseerrRequestStatus.failed => l10n.mediaStatusFailed,
    JellyseerrRequestStatus.completed => l10n.mediaRequestCompleted,
  };
}
