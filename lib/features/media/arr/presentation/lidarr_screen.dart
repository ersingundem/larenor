import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../providers/lidarr_providers.dart';
import 'widgets/arr_add_screen.dart';
import 'widgets/arr_connect_form.dart';
import 'widgets/arr_dashboard_body.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';

class LidarrScreen extends ConsumerWidget {
  const LidarrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(lidarrConnectionProvider);

    return connectionAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text('$error'))),
      data: (config) {
        if (config == null) {
          return ArrConnectForm(
            title: 'Lidarr',
            urlHint: 'http://lidarr.local:8686',
            discoverySignature: ServiceSignatures.lidarr,
            onConnect: (url, key) => ref
                .read(lidarrConnectionProvider.notifier)
                .signIn(baseUrl: url, apiKey: key),
          );
        }

        final queue = ref.watch(lidarrQueueProvider);
        final calendar = ref.watch(lidarrCalendarProvider);

        return ServiceRootScaffold(
          title: 'Lidarr',
          leading: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () {
              ref.invalidate(lidarrQueueProvider);
              ref.invalidate(lidarrCalendarProvider);
            },
            child: const Icon(CupertinoIcons.refresh),
          ),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.of(context).push(
              CupertinoPageRoute(
                builder: (_) => ArrAddScreen(
                  title: AppLocalizations.of(context).arrAddArtistTitle,
                  searchHint: AppLocalizations.of(context).arrSearchArtists,
                  onLookup: (term) =>
                      ref.read(lidarrClientProvider)!.lookup(term),
                  loadQualityProfiles: () =>
                      ref.read(lidarrClientProvider)!.getQualityProfiles(),
                  loadRootFolders: () =>
                      ref.read(lidarrClientProvider)!.getRootFolders(),
                  loadMetadataProfiles: () =>
                      ref.read(lidarrClientProvider)!.getMetadataProfiles(),
                  onAdd: (result, profileId, folder, metadataProfileId) async {
                    await ref
                        .read(lidarrClientProvider)!
                        .add(
                          result: result,
                          qualityProfileId: profileId,
                          rootFolderPath: folder,
                          metadataProfileId: metadataProfileId,
                        );
                    ref.invalidate(lidarrCalendarProvider);
                  },
                ),
              ),
            ),
            child: const Icon(CupertinoIcons.add),
          ),
          slivers: ArrDashboardBody(
            queue: queue,
            calendar: calendar,
          ).slivers(context),
        );
      },
    );
  }
}
