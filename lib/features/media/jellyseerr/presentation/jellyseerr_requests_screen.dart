import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../providers/jellyseerr_providers.dart';
import 'jellyseerr_status_label.dart';

class JellyseerrRequestsScreen extends ConsumerWidget {
  const JellyseerrRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requestsAsync = ref.watch(jellyseerrMyRequestsProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(AppLocalizations.of(context).jellyseerrMyRequestsTitle),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(jellyseerrMyRequestsProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: requestsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(
            child: Text(
              AppLocalizations.of(context).adminLoadError(error.toString()),
            ),
          ),
          data: (requests) {
            if (requests.isEmpty) {
              return Center(
                child: Text(
                  AppLocalizations.of(context).jellyseerrNoRequestsYet,
                ),
              );
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
