import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/direct_home_access.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../../../../shared/widgets/service_route_status_scaffold.dart';
import '../../arr/presentation/widgets/arr_connect_form.dart';
import '../providers/prowlarr_providers.dart';

class ProwlarrConnectScreen extends ConsumerWidget {
  const ProwlarrConnectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the exact connection notifier alive while this standalone route is open.
    final state = ref.watch(prowlarrConnectionProvider);
    if (state.isLoading) {
      return ServiceRouteStatusScaffold(
        title: 'Prowlarr',
        label: AppLocalizations.of(context).commonLoading,
        statusKey: const ValueKey('prowlarr-connect-status'),
        loading: true,
      );
    }
    final error = state.error;
    final pending =
        error is DirectHomeAccessException &&
        const {'pending_mutation', 'write_unconfirmed'}.contains(error.code);
    if (state.hasError && !pending) {
      return ServiceRouteStatusScaffold(
        title: 'Prowlarr',
        label: AppLocalizations.of(context).mediaErrorUnreachable,
        statusKey: const ValueKey('prowlarr-connect-status'),
        actionLabel: AppLocalizations.of(context).commonRetry,
        actionKey: const ValueKey('prowlarr-connect-retry'),
        onAction: () => ref.invalidate(prowlarrConnectionProvider),
      );
    }
    final connection = ref.read(prowlarrConnectionProvider.notifier);
    final store = ref.read(prowlarrCredentialsStoreProvider);
    return ArrConnectForm(
      title: 'Prowlarr',
      apiKeyHint: AppLocalizations.of(context).prowlarrApiKeyHint,
      urlHint: pending ? '' : 'http://prowlarr.local:9696',
      discoverySignature: pending ? null : ServiceSignatures.prowlarr,
      onClear: pending
          ? (isCurrent) => store.clear(isCurrent: isCurrent)
          : null,
      onConnect: (url, key, isCurrent) async {
        await connection.signIn(
          baseUrl: url,
          apiKey: key,
          isCurrent: isCurrent,
        );
        if (context.mounted && isCurrent()) {
          Navigator.of(context).maybePop();
        }
      },
    );
  }
}
