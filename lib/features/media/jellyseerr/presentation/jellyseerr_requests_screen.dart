import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/jellyseerr_providers.dart';

class JellyseerrRequestsScreen extends ConsumerWidget {
  const JellyseerrRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requestsAsync = ref.watch(jellyseerrMyRequestsProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('My Requests'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(jellyseerrMyRequestsProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: requestsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (requests) {
            if (requests.isEmpty) {
              return const Center(child: Text('No requests yet'));
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
                        additionalInfo: Text(request.status.label),
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
