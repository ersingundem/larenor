import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../providers/jellyseerr_providers.dart';
import 'jellyseerr_status_label.dart';

class JellyseerrRequestsScreen extends ConsumerWidget {
  const JellyseerrRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requestsAsync = ref.watch(jellyseerrMyRequestsProvider);
    final l10n = AppLocalizations.of(context);

    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.jellyseerrMyRequestsTitle),
        trailing: Semantics(
          label: l10n.commonRefresh,
          child: CupertinoButton(
            key: const ValueKey('jellyseerr-requests-refresh'),
            padding: EdgeInsets.zero,
            minimumSize: const Size.square(48),
            onPressed: () => ref.invalidate(jellyseerrMyRequestsProvider),
            child: const ExcludeSemantics(child: Icon(CupertinoIcons.refresh)),
          ),
        ),
      ),
      child: SafeArea(
        child: requestsAsync.when(
          loading: () =>
              _RequestsStatus(label: l10n.commonLoading, loading: true),
          error: (_, _) => _RequestsStatus(label: l10n.mediaErrorUnreachable),
          data: (requests) {
            if (requests.isEmpty) {
              return _RequestsStatus(label: l10n.jellyseerrNoRequestsYet);
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final request in requests)
                      CupertinoListTile(
                        leading: Icon(
                          request.mediaType == 'tv'
                              ? CupertinoIcons.tv
                              : CupertinoIcons.film,
                        ),
                        title: Text(request.displayTitle),
                        additionalInfo: Text(
                          jellyseerrRequestStatusLabel(context, request.status),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RequestsStatus extends StatelessWidget {
  const _RequestsStatus({required this.label, this.loading = false});

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      key: const ValueKey('jellyseerr-requests-status'),
      label: label,
      liveRegion: true,
      excludeSemantics: true,
      child: loading
          ? const CupertinoActivityIndicator()
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Text(label, textAlign: TextAlign.center),
            ),
    ),
  );
}
