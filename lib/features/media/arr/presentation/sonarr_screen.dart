import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/direct_home_access.dart';
import '../../../health/data/integration_health.dart';
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
      skipLoadingOnReload: false,
      skipLoadingOnRefresh: false,
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) {
        if (error is DirectHomeAccessException &&
            const {'pending_mutation', 'write_unconfirmed'}.contains(error.code)) {
          final connection = ref.read(sonarrConnectionProvider.notifier);
          final store = ref.read(sonarrCredentialsStoreProvider);
          return ArrConnectForm(
            title: 'Sonarr',
            urlHint: '',
            onClear: (isCurrent) => store.clear(isCurrent: isCurrent),
            onConnect: (url, key, isCurrent) => connection.signIn(
              baseUrl: url,
              apiKey: key,
              isCurrent: isCurrent,
            ),
          );
        }
        return CupertinoPageScaffold(
          child: Center(
            child: Text(AppLocalizations.of(context).mediaErrorUnreachable),
          ),
        );
      },
      data: (config) {
        if (config == null) {
          return ArrConnectForm(
            title: 'Sonarr',
            urlHint: 'http://sonarr.local:8989',
            discoverySignature: ServiceSignatures.sonarr,
            onConnect: (url, key, isCurrent) => ref
                .read(sonarrConnectionProvider.notifier)
                .signIn(baseUrl: url, apiKey: key, isCurrent: isCurrent),
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
            onPressed: () => openArrAddScreen(
              context: context,
              ref: ref,
              integration: IntegrationId.sonarr,
              connectionProvider: sonarrConnectionProvider,
              clientProvider: sonarrClientProvider,
              title: AppLocalizations.of(context).arrAddSeriesTitle,
              searchHint: AppLocalizations.of(context).arrSearchTvShows,
              metadata: false,
              onAdded: () => ref.invalidate(sonarrCalendarProvider),
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
