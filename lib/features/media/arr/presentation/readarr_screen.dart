import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../health/data/integration_health.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../providers/readarr_providers.dart';
import 'widgets/arr_add_screen.dart';
import 'widgets/arr_connect_form.dart';
import 'widgets/arr_dashboard_body.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';

class ReadarrScreen extends ConsumerWidget {
  const ReadarrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(readarrConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnReload: false,
      skipLoadingOnRefresh: false,
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) => CupertinoPageScaffold(
        child: Center(
          child: Text(AppLocalizations.of(context).mediaErrorUnreachable),
        ),
      ),
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

        return ServiceRootScaffold(
          title: 'Readarr',
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
            onPressed: () => openArrAddScreen(
              context: context,
              ref: ref,
              integration: IntegrationId.readarr,
              connectionProvider: readarrConnectionProvider,
              clientProvider: readarrClientProvider,
              title: AppLocalizations.of(context).arrAddAuthorTitle,
              searchHint: AppLocalizations.of(context).arrSearchAuthors,
              metadata: true,
              onAdded: () => ref.invalidate(readarrCalendarProvider),
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
