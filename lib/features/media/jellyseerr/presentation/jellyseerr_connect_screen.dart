import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/direct_home_access.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/discovery/service_signatures.dart';
import '../../arr/presentation/widgets/arr_connect_form.dart';
import '../providers/jellyseerr_providers.dart';

class JellyseerrConnectScreen extends ConsumerWidget {
  const JellyseerrConnectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the exact connection notifier alive while this standalone route is open.
    final state = ref.watch(jellyseerrConnectionProvider);
    if (state.isLoading) {
      return const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    final error = state.error;
    final pending =
        error is DirectHomeAccessException &&
        const {'pending_mutation', 'write_unconfirmed'}.contains(error.code);
    if (state.hasError && !pending) {
      return CupertinoPageScaffold(
        child: Center(
          child: Text(AppLocalizations.of(context).mediaErrorUnreachable),
        ),
      );
    }
    final connection = ref.read(jellyseerrConnectionProvider.notifier);
    final store = ref.read(jellyseerrCredentialsStoreProvider);
    return ArrConnectForm(
      title: 'Jellyseerr',
      apiKeyHint: AppLocalizations.of(context).jellyseerrApiKeyHint,
      urlHint: pending ? '' : 'http://jellyseerr.local:5055',
      discoverySignature: pending ? null : ServiceSignatures.jellyseerr,
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
