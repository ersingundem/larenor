import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../providers/readarr_providers.dart';
import 'widgets/arr_add_screen.dart';
import 'widgets/arr_connect_form.dart';
import 'widgets/arr_dashboard_body.dart';

class ReadarrScreen extends ConsumerWidget {
  const ReadarrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(readarrConnectionProvider);

    return connectionAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text('$error'))),
      data: (config) {
        if (config == null) {
          return ArrConnectForm(
            title: 'Readarr',
            urlHint: 'http://readarr.local:8787',
            discoverySignature: ServiceSignatures.readarr,
            onConnect: (url, key) => ref
                .read(readarrConnectionProvider.notifier)
                .signIn(baseUrl: url, apiKey: key),
          );
        }

        final queue = ref.watch(readarrQueueProvider);
        final calendar = ref.watch(readarrCalendarProvider);

        return CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(
            middle: const Text('Readarr'),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () {
                ref.invalidate(readarrQueueProvider);
                ref.invalidate(readarrCalendarProvider);
              },
              child: const Icon(CupertinoIcons.refresh),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute(
                  builder: (_) => ArrAddScreen(
                    title: AppLocalizations.of(context).arrAddAuthorTitle,
                    searchHint: AppLocalizations.of(context).arrSearchAuthors,
                    onLookup: (term) =>
                        ref.read(readarrClientProvider)!.lookup(term),
                    loadQualityProfiles: () =>
                        ref.read(readarrClientProvider)!.getQualityProfiles(),
                    loadRootFolders: () =>
                        ref.read(readarrClientProvider)!.getRootFolders(),
                    loadMetadataProfiles: () =>
                        ref.read(readarrClientProvider)!.getMetadataProfiles(),
                    onAdd:
                        (result, profileId, folder, metadataProfileId) async {
                          await ref
                              .read(readarrClientProvider)!
                              .add(
                                result: result,
                                qualityProfileId: profileId,
                                rootFolderPath: folder,
                                metadataProfileId: metadataProfileId,
                              );
                          ref.invalidate(readarrCalendarProvider);
                        },
                  ),
                ),
              ),
              child: const Icon(CupertinoIcons.add),
            ),
          ),
          child: SafeArea(
            child: ArrDashboardBody(queue: queue, calendar: calendar),
          ),
        );
      },
    );
  }
}
