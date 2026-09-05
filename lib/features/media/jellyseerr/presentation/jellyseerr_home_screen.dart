import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../health/data/action_receipt.dart';
import '../../../health/data/integration_health.dart';
import '../../../health/providers/action_providers.dart';
import '../../data/media_api_exception.dart';
import '../../hub/presentation/media_session_state.dart';
import '../data/models/jellyseerr_result.dart';
import '../providers/jellyseerr_providers.dart';
import 'jellyseerr_connect_screen.dart';
import 'jellyseerr_requests_screen.dart';
import 'jellyseerr_status_label.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/theme/spacing.dart';

class JellyseerrHomeScreen extends ConsumerWidget {
  const JellyseerrHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(jellyseerrConnectionProvider);

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
    extends MediaSessionState<_JellyseerrSearchScreen> {
  List<JellyseerrResult>? _results;
  bool _searching = false;
  final _requestingIds = <String>{};
  final _blockedIds = <String>{};
  final _receipts = <String, String>{};
  int _queryGeneration = 0;
  bool _visible = true;
  String? _message;
  String _key(JellyseerrResult result) => '${result.mediaType}:${result.id}';
  bool _current(int generation) =>
      sessionCurrent(generation) &&
      _visible &&
      ModalRoute.of(context)?.isCurrent == true;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (_visible && !visible) {
      sessionGeneration++;
      clearPendingInteraction();
    }
    _visible = visible;
  }

  @override
  void clearPendingInteraction() {
    _queryGeneration++;
    _results = null;
    _searching = false;
    _message = null;
    // An accepted/uncertain write is never made replayable by idle or hiding.
  }

  Future<void> _search(String query) async {
    final generation = sessionGeneration;
    if (!_current(generation)) return;
    final config = ref.read(jellyseerrConnectionProvider);
    if (config.isLoading || config.hasError || config.value == null) return;
    final sequence = ++_queryGeneration;
    final client = ref.read(jellyseerrClientProvider);
    if (client == null || query.trim().isEmpty) {
      setState(() {
        _results = null;
        _searching = false;
      });
      return;
    }
    bool current() =>
        _current(generation) &&
        sequence == _queryGeneration &&
        identical(client, ref.read(jellyseerrClientProvider));
    setState(() {
      _searching = true;
      _results = null;
      _message = null;
    });
    try {
      final results = await client.search(query.trim());
      if (current()) setState(() => _results = results);
    } catch (error) {
      if (current()) setState(() => _message = _readFailure(error));
    } finally {
      if (current()) setState(() => _searching = false);
    }
  }

  String _readFailure(Object error) {
    final l10n = AppLocalizations.of(context);
    return switch (error) {
      MediaApiException(statusCode: 401) => l10n.healthAuthenticationRequired,
      MediaApiException(statusCode: 403) => l10n.healthPermissionDenied,
      _ => l10n.mediaErrorUnreachable,
    };
  }

  Future<void> _request(
    JellyseerrResult result,
    int generation,
    int queryGeneration,
  ) async {
    final key = _key(result);
    if (!_current(generation) ||
        queryGeneration != _queryGeneration ||
        _requestingIds.contains(key) ||
        _blockedIds.contains(key) ||
        _results?.contains(result) != true ||
        result.status != JellyseerrMediaStatus.unknown) {
      return;
    }
    final config = ref.read(jellyseerrConnectionProvider);
    if (config.isLoading || config.hasError || config.value == null) return;
    final client = ref.read(jellyseerrClientProvider);
    if (client == null) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _requestingIds.add(key));
    try {
      final receipt = await ref
          .read(actionControllerProvider)
          .execute<void>(
            key: ActionKey(
              integration: IntegrationId.jellyseerr,
              target: 'legacy:$key',
              action: 'request',
            ),
            send: () async {
              if (!_current(generation) ||
                  queryGeneration != _queryGeneration ||
                  !identical(client, ref.read(jellyseerrClientProvider))) {
                throw MediaApiException('Selection expired', statusCode: 409);
              }
              await client.requestMedia(
                mediaType: result.mediaType,
                mediaId: result.id,
              );
            },
            classifyFailure: (error) => switch (error) {
              MediaApiException(statusCode: 401) =>
                ActionFailure.authentication,
              MediaApiException(statusCode: 403) => ActionFailure.permission,
              MediaApiException(statusCode: final int code)
                  when code >= 400 && code < 500 =>
                ActionFailure.rejected,
              _ => ActionFailure.unknown,
            },
          );
      if (receipt.status == ActionStatus.accepted ||
          receipt.status == ActionStatus.confirmed ||
          receipt.status == ActionStatus.unknown) {
        _blockedIds.add(key);
      }
      _receipts[key] = switch (receipt.status) {
        ActionStatus.accepted ||
        ActionStatus.confirmed => l10n.mediaRequestAccepted,
        ActionStatus.unknown => l10n.mediaWriteUnknown,
        _ => switch (receipt.failure) {
          ActionFailure.authentication => l10n.healthAuthenticationRequired,
          ActionFailure.permission => l10n.healthPermissionDenied,
          _ => l10n.mediaErrorUnreachable,
        },
      };
      if (!_current(generation)) return;
      setState(() {});
      if (receipt.status == ActionStatus.accepted ||
          receipt.status == ActionStatus.confirmed) {
        ref.invalidate(jellyseerrMyRequestsProvider);
      }
    } catch (error) {
      // Controller lifetime/transport ambiguity must not reopen an old request.
      _blockedIds.add(key);
      _receipts[key] = l10n.mediaWriteUnknown;
    } finally {
      _requestingIds.remove(key);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    watchMediaAccount(IntegrationId.jellyseerr, jellyseerrConnectionProvider);
    final generation = sessionGeneration;
    final queryGeneration = _queryGeneration;
    final ready = _current(generation);
    final results = ready ? _results : null;

    return ServiceRootScaffold(
      title: 'Jellyseerr',
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () => Navigator.of(context).push(
          CupertinoPageRoute(builder: (_) => const JellyseerrRequestsScreen()),
        ),
        child: const Icon(CupertinoIcons.list_bullet),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: CupertinoSearchTextField(
              placeholder: AppLocalizations.of(context)
                  .jellyseerrSearchPlaceholder,
              enabled: ready,
              onSubmitted: _search,
              onChanged: (value) {
                if (value.trim().isEmpty) _search(value);
              },
            ),
          ),
        ),
        if (sessionExpired || _message != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Text(
                sessionExpired
                    ? AppLocalizations.of(context).mediaSelectionExpired
                    : _message!,
              ),
            ),
          ),
        if (_searching)
          const SliverToBoxAdapter(
            child: Center(child: CupertinoActivityIndicator()),
          ),
        if (results == null)
          SliverFilledMessage(
            child: Text(AppLocalizations.of(context).jellyseerrSearchEmpty),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final result = results[index];
              return _ResultTile(
                result: result,
                requesting: _requestingIds.contains(_key(result)),
                receipt: _receipts[_key(result)],
                enabled: ready && !_blockedIds.contains(_key(result)),
                onRequest: () => _request(result, generation, queryGeneration),
              );
            }, childCount: results.length),
          ),
      ],
    );
  }
}

class _ResultTile extends ConsumerWidget {
  const _ResultTile({
    required this.result,
    required this.requesting,
    required this.onRequest,
    required this.enabled,
    this.receipt,
  });

  final JellyseerrResult result;
  final bool requesting;
  final VoidCallback onRequest;
  final bool enabled;
  final String? receipt;

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
      trailing: receipt != null
          ? ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(receipt!, style: AppText.caption1),
            )
          : alreadyRequested
          ? Text(
              jellyseerrStatusLabel(context, result.status),
              style: TextStyle(
                fontSize: AppText.caption1.fontSize,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            )
          : requesting
          ? const CupertinoActivityIndicator()
          : CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: enabled ? onRequest : null,
              child: Text(AppLocalizations.of(context).jellyseerrRequestButton),
            ),
    );
  }
}
