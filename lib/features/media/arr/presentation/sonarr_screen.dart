import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../providers/sonarr_providers.dart';
import 'widgets/arr_add_screen.dart';
import 'widgets/arr_connect_form.dart';
import 'widgets/arr_dashboard_body.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';

class SonarrScreen extends ConsumerWidget {
  const SonarrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(sonarrConnectionProvider);

    return connectionAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text('$error'))),
      data: (config) {
        if (config == null) {
          return ArrConnectForm(
            title: 'Sonarr',
            urlHint: 'http://sonarr.local:8989',
            discoverySignature: ServiceSignatures.sonarr,
            onConnect: (url, key) => ref
                .read(sonarrConnectionProvider.notifier)
                .signIn(baseUrl: url, apiKey: key),
          );
        }

        final queue = ref.watch(sonarrQueueProvider);
        final calendar = ref.watch(sonarrCalendarProvider);

        return ServiceRootScaffold(
          title: 'Sonarr',
          leading: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () {
              ref.invalidate(sonarrQueueProvider);
              ref.invalidate(sonarrCalendarProvider);
            },
            child: const Icon(CupertinoIcons.refresh),
          ),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.of(context).push(
              CupertinoPageRoute(
                builder: (_) => ArrAddScreen(
                  title: AppLocalizations.of(context).arrAddSeriesTitle,
                  searchHint: AppLocalizations.of(context).arrSearchTvShows,
                  onLookup: (term) =>
                      ref.read(sonarrClientProvider)!.lookup(term),
                  loadQualityProfiles: () =>
                      ref.read(sonarrClientProvider)!.getQualityProfiles(),
                  loadRootFolders: () =>
                      ref.read(sonarrClientProvider)!.getRootFolders(),
                  onAdd: (result, profileId, folder, _) async {
                    await ref
                        .read(sonarrClientProvider)!
                        .add(
                          result: result,
                          qualityProfileId: profileId,
                          rootFolderPath: folder,
                        );
                    ref.invalidate(sonarrCalendarProvider);
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
