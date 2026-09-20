import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/direct_home_access.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../../../../shared/widgets/service_route_status_scaffold.dart';
import '../../arr/presentation/widgets/arr_connect_form.dart';
import '../providers/bazarr_providers.dart';

class BazarrConnectScreen extends ConsumerWidget {
  const BazarrConnectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the exact connection notifier alive while this standalone route is open.
    final state = ref.watch(bazarrConnectionProvider);
    if (state.isLoading) {
      return ServiceRouteStatusScaffold(
        title: 'Bazarr',
        label: AppLocalizations.of(context).commonLoading,
        statusKey: const ValueKey('bazarr-connect-status'),
        loading: true,
      );
    }
    final error = state.error;
    final pending =
        error is DirectHomeAccessException &&
        const {'pending_mutation', 'write_unconfirmed'}.contains(error.code);
    if (state.hasError && !pending) {
      return ServiceRouteStatusScaffold(
        title: 'Bazarr',
        label: AppLocalizations.of(context).mediaErrorUnreachable,
        statusKey: const ValueKey('bazarr-connect-status'),
        actionLabel: AppLocalizations.of(context).commonRetry,
        actionKey: const ValueKey('bazarr-connect-retry'),
        onAction: () => ref.invalidate(bazarrConnectionProvider),
      );
    }
    final connection = ref.read(bazarrConnectionProvider.notifier);
    final store = ref.read(bazarrCredentialsStoreProvider);
    return ArrConnectForm(
      title: 'Bazarr',
      apiKeyHint: AppLocalizations.of(context).bazarrApiKeyHint,
      urlHint: pending ? '' : 'http://bazarr.local:6767',
      discoverySignature: pending ? null : ServiceSignatures.bazarr,
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
