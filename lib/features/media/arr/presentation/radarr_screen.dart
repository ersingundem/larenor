import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/direct_home_access.dart';
import '../../../health/data/integration_health.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../providers/radarr_providers.dart';
import 'widgets/arr_add_screen.dart';
import 'widgets/arr_connect_form.dart';
import 'widgets/arr_dashboard_body.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/service_route_status_scaffold.dart';

class RadarrScreen extends ConsumerWidget {
  const RadarrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(radarrConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnReload: false,
      skipLoadingOnRefresh: false,
      loading: () => ServiceRouteStatusScaffold(
        title: 'Radarr',
        label: AppLocalizations.of(context).commonLoading,
        statusKey: const ValueKey('radarr-home-status'),
        loading: true,
      ),
      error: (error, _) {
        if (error is DirectHomeAccessException &&
            const {
              'pending_mutation',
              'write_unconfirmed',
            }.contains(error.code)) {
          final connection = ref.read(radarrConnectionProvider.notifier);
          final store = ref.read(radarrCredentialsStoreProvider);
          return ArrConnectForm(
            title: 'Radarr',
            urlHint: '',
            onClear: (isCurrent) => store.clear(isCurrent: isCurrent),
            onConnect: (url, key, isCurrent) => connection.signIn(
              baseUrl: url,
              apiKey: key,
              isCurrent: isCurrent,
            ),
          );
        }
        return ServiceRouteStatusScaffold(
          title: 'Radarr',
          label: AppLocalizations.of(context).mediaErrorUnreachable,
          statusKey: const ValueKey('radarr-home-status'),
          actionLabel: AppLocalizations.of(context).commonRetry,
          actionKey: const ValueKey('radarr-home-retry'),
          onAction: () => ref.invalidate(radarrConnectionProvider),
        );
      },
      data: (config) {
        if (config == null) {
          return ArrConnectForm(
            title: 'Radarr',
            urlHint: 'http://radarr.local:7878',
            discoverySignature: ServiceSignatures.radarr,
            onConnect: (url, key, isCurrent) => ref
                .read(radarrConnectionProvider.notifier)
                .signIn(baseUrl: url, apiKey: key, isCurrent: isCurrent),
          );
        }

        final queue = ref.watch(radarrQueueProvider);
        final calendar = ref.watch(radarrCalendarProvider);

        return ServiceRootScaffold(
          title: 'Radarr',
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
            onPressed: () => openArrAddScreen(
              context: context,
              ref: ref,
              integration: IntegrationId.radarr,
              connectionProvider: radarrConnectionProvider,
              clientProvider: radarrClientProvider,
              title: AppLocalizations.of(context).arrAddMovieTitle,
              searchHint: AppLocalizations.of(context).arrSearchMovies,
              metadata: false,
              onAdded: () => ref.invalidate(radarrCalendarProvider),
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
