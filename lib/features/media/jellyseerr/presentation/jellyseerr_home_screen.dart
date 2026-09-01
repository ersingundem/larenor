import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../data/models/jellyseerr_result.dart';
import '../providers/jellyseerr_providers.dart';
import 'jellyseerr_connect_screen.dart';
import 'jellyseerr_requests_screen.dart';
import 'jellyseerr_status_label.dart';

class JellyseerrHomeScreen extends ConsumerWidget {
  const JellyseerrHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(jellyseerrConnectionProvider);

    return connectionAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text(error.toString()))),
      data: (config) {
        if (config == null) return const JellyseerrConnectScreen();
        return const _JellyseerrSearchScreen();
      },
    );
  }
}

class _JellyseerrSearchScreen extends ConsumerStatefulWidget {
  const _JellyseerrSearchScreen();

  @override
  ConsumerState<_JellyseerrSearchScreen> createState() =>
      _JellyseerrSearchScreenState();
}

class _JellyseerrSearchScreenState
    extends ConsumerState<_JellyseerrSearchScreen> {
  List<JellyseerrResult>? _results;
  String? _lastQuery;
  bool _searching = false;
  final _requestingIds = <int>{};

  Future<void> _search(String query) async {
    final client = ref.read(jellyseerrClientProvider);
    if (client == null || query.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    _lastQuery = query.trim();
    setState(() => _searching = true);
    try {
      final results = await client.search(query.trim());
      if (mounted) setState(() => _results = results);
    } catch (_) {
      if (mounted) setState(() => _results = []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _request(JellyseerrResult result) async {
    final client = ref.read(jellyseerrClientProvider);
    if (client == null) return;
    setState(() => _requestingIds.add(result.id));
    try {
      await client.requestMedia(
        mediaType: result.mediaType,
        mediaId: result.id,
      );
      // Re-run the last search so the row picks up its new "pending" status.
      final query = _lastQuery;
      if (query != null) await _search(query);
    } catch (_) {
      // The row's status simply won't update; user can retry.
    } finally {
      if (mounted) setState(() => _requestingIds.remove(result.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Jellyseerr'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).push(
            CupertinoPageRoute(
              builder: (_) => const JellyseerrRequestsScreen(),
            ),
          ),
          child: const Icon(CupertinoIcons.list_bullet),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoSearchTextField(
                placeholder: AppLocalizations.of(context)
                    .jellyseerrSearchPlaceholder,
                onSubmitted: _search,
                onChanged: (value) {
                  if (value.trim().isEmpty) setState(() => _results = null);
                },
              ),
            ),
            if (_searching) const CupertinoActivityIndicator(),
            Expanded(
              child: _results == null
                  ? Center(
                      child: Text(
                        AppLocalizations.of(context).jellyseerrSearchEmpty,
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results!.length,
                      itemBuilder: (context, index) {
                        final result = _results![index];
                        return _ResultTile(
                          result: result,
                          requesting: _requestingIds.contains(result.id),
                          onRequest: () => _request(result),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultTile extends ConsumerWidget {
  const _ResultTile({
    required this.result,
    required this.requesting,
    required this.onRequest,
  });

  final JellyseerrResult result;
  final bool requesting;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(jellyseerrClientProvider);
    final posterUrl = client?.posterUrl(result.posterPath);
    final alreadyRequested = result.status != JellyseerrMediaStatus.unknown;

    return CupertinoListTile(
      leading: SizedBox(
        width: 40,
        height: 60,
        child: posterUrl == null
            ? const Icon(CupertinoIcons.film)
            : ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  posterUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(CupertinoIcons.film),
                ),
              ),
      ),
      title: Text(result.displayTitle),
      subtitle: Text(
        result.isTv
            ? AppLocalizations.of(context).jellyseerrTvShow
            : AppLocalizations.of(context).jellyseerrMovie,
      ),
      trailing: alreadyRequested
          ? Text(
              jellyseerrStatusLabel(context, result.status),
              style: TextStyle(
                fontSize: 12,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            )
          : requesting
          ? const CupertinoActivityIndicator()
          : CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: onRequest,
              child: Text(AppLocalizations.of(context).jellyseerrRequestButton),
            ),
    );
  }
}
