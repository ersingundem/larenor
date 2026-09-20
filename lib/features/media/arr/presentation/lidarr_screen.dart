import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/direct_home_access.dart';
import '../../../health/data/integration_health.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../providers/lidarr_providers.dart';
import 'widgets/arr_add_screen.dart';
import 'widgets/arr_connect_form.dart';
import 'widgets/arr_dashboard_body.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/service_route_status_scaffold.dart';

class LidarrScreen extends ConsumerWidget {
  const LidarrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(lidarrConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnReload: false,
      skipLoadingOnRefresh: false,
      loading: () => ServiceRouteStatusScaffold(
        title: 'Lidarr',
        label: AppLocalizations.of(context).commonLoading,
        statusKey: const ValueKey('lidarr-home-status'),
        loading: true,
      ),
      error: (error, _) {
        if (error is DirectHomeAccessException &&
            const {
              'pending_mutation',
              'write_unconfirmed',
            }.contains(error.code)) {
          final connection = ref.read(lidarrConnectionProvider.notifier);
          final store = ref.read(lidarrCredentialsStoreProvider);
          return ArrConnectForm(
            title: 'Lidarr',
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
          title: 'Lidarr',
          label: AppLocalizations.of(context).mediaErrorUnreachable,
          statusKey: const ValueKey('lidarr-home-status'),
          actionLabel: AppLocalizations.of(context).commonRetry,
          actionKey: const ValueKey('lidarr-home-retry'),
          onAction: () => ref.invalidate(lidarrConnectionProvider),
        );
      },
      data: (config) {
        if (config == null) {
          return ArrConnectForm(
            title: 'Lidarr',
            urlHint: 'http://lidarr.local:8686',
            discoverySignature: ServiceSignatures.lidarr,
            onConnect: (url, key, isCurrent) => ref
                .read(lidarrConnectionProvider.notifier)
                .signIn(baseUrl: url, apiKey: key, isCurrent: isCurrent),
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
            onPressed: () => openArrAddScreen(
              context: context,
              ref: ref,
              integration: IntegrationId.lidarr,
              connectionProvider: lidarrConnectionProvider,
              clientProvider: lidarrClientProvider,
              title: AppLocalizations.of(context).arrAddArtistTitle,
              searchHint: AppLocalizations.of(context).arrSearchArtists,
              metadata: true,
              onAdded: () => ref.invalidate(lidarrCalendarProvider),
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
