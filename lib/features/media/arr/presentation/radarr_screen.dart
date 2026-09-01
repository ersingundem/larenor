import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/discovery/service_signatures.dart';
import '../providers/radarr_providers.dart';
import 'widgets/arr_add_screen.dart';
import 'widgets/arr_connect_form.dart';
import 'widgets/arr_dashboard_body.dart';

class RadarrScreen extends ConsumerWidget {
  const RadarrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(radarrConnectionProvider);

    return connectionAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text('$error'))),
      data: (config) {
        if (config == null) {
          return ArrConnectForm(
            title: 'Radarr',
            urlHint: 'http://radarr.local:7878',
            discoverySignature: ServiceSignatures.radarr,
            onConnect: (url, key) => ref
                .read(radarrConnectionProvider.notifier)
                .signIn(baseUrl: url, apiKey: key),
          );
        }

        final queue = ref.watch(radarrQueueProvider);
        final calendar = ref.watch(radarrCalendarProvider);

        return CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(
            middle: const Text('Radarr'),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () {
                ref.invalidate(radarrQueueProvider);
                ref.invalidate(radarrCalendarProvider);
              },
              child: const Icon(CupertinoIcons.refresh),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute(
                  builder: (_) => ArrAddScreen(
                    title: 'Add Movie',
                    searchHint: 'Search movies',
                    onLookup: (term) =>
                        ref.read(radarrClientProvider)!.lookup(term),
                    loadQualityProfiles: () =>
                        ref.read(radarrClientProvider)!.getQualityProfiles(),
                    loadRootFolders: () =>
                        ref.read(radarrClientProvider)!.getRootFolders(),
                    onAdd: (result, profileId, folder, _) async {
                      await ref
                          .read(radarrClientProvider)!
                          .add(
                            result: result,
                            qualityProfileId: profileId,
                            rootFolderPath: folder,
                          );
                      ref.invalidate(radarrCalendarProvider);
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
