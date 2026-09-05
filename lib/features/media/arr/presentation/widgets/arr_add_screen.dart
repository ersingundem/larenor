import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../../../../core/app_interaction_scope.dart';
import '../../../../health/data/health_configuration.dart';
import '../../../../health/data/integration_health.dart';
import '../../../data/media_api_exception.dart';
import '../../../hub/presentation/media_session_state.dart';
import '../../data/arr_client.dart';
import '../../data/arr_config.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../data/models/arr_lookup_result.dart';
import '../../data/models/arr_picker_options.dart';

/// Shared "search and add" flow for Sonarr/Radarr/Lidarr/Readarr: lookup →
/// pick a result → pick quality profile + root folder (+ metadata profile
/// for Lidarr/Readarr) → confirm. Parameterized entirely by callbacks so
/// the same widget drives all four services.
class ArrAddScreen extends ConsumerStatefulWidget {
  const ArrAddScreen({
    super.key,
    required this.title,
    required this.searchHint,
    required this.onLookup,
    required this.loadQualityProfiles,
    required this.loadRootFolders,
    required this.onAdd,
    this.loadMetadataProfiles,
    this.initialQuery,
    this.sourceCurrent,
    this.connectionProvider,
    this.integration = IntegrationId.radarr,
  });

  final bool Function()? sourceCurrent;
  final ProviderListenable<AsyncValue<ArrConfig?>>? connectionProvider;
  final IntegrationId integration;
  final String title;
  final String searchHint;
  final String? initialQuery;
  final Future<List<ArrLookupResult>> Function(String term) onLookup;
  final Future<List<ArrQualityProfile>> Function() loadQualityProfiles;
  final Future<List<ArrRootFolder>> Function() loadRootFolders;

  /// Lidarr/Readarr only — Sonarr/Radarr don't pass this, so the third
  /// picker section simply doesn't render for them.
  final Future<List<ArrMetadataProfile>> Function()? loadMetadataProfiles;

  final Future<void> Function(
    ArrLookupResult result,
    int qualityProfileId,
    String rootFolderPath,
    int? metadataProfileId,
  )
  onAdd;

  @override
  ConsumerState<ArrAddScreen> createState() => _ArrAddScreenState();
}

class _ArrAddScreenState extends MediaSessionState<ArrAddScreen> {
  int _queryGeneration = 0;
  bool _submissionBlocked = false;
  Route<bool>? _confirmation;
  bool _visible = true;
  bool get _sourceCurrent => widget.sourceCurrent?.call() ?? true;
  bool _current(int epoch, {bool ownModal = false}) =>
      sessionCurrent(epoch) &&
      _sourceCurrent &&
      _visible &&
      (ModalRoute.of(context)?.isCurrent == true ||
          (ownModal && _confirmation?.isCurrent == true));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible =
        TickerMode.valuesOf(context).enabled ||
        _confirmation?.isCurrent == true;
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
    _adding = false;
    final route = _confirmation;
    _confirmation = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  List<ArrLookupResult>? _results;
  bool _searching = false;
  bool _adding = false;
  String? _error;
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.initialQuery != null) _search(widget.initialQuery!);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.connectionProvider;
    if (provider != null) watchMediaAccount(widget.integration, provider);
    final ready = _current(sessionGeneration);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(widget.title)),
      child: SafeArea(
        child: Column(
          children: [
            if (sessionExpired || !_sourceCurrent)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(AppLocalizations.of(context).mediaSelectionExpired),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoSearchTextField(
                placeholder: widget.searchHint,
                controller: _controller,
                enabled: ready && !_adding && !_submissionBlocked,
                onSubmitted: _search,
              ),
            ),
            if (_searching || _adding) const CupertinoActivityIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
              ),
            Expanded(
              child: !ready || _results == null
                  ? Center(
                      child: Text(AppLocalizations.of(context).arrSearchToAdd),
                    )
                  : ListView.builder(
                      itemCount: _results!.length,
                      itemBuilder: (context, index) {
                        final result = _results![index];
                        return CupertinoListTile(
                          title: Text(result.title),
                          subtitle: result.year != null
                              ? Text('${result.year}')
                              : null,
                          trailing: result.alreadyAdded
                              ? Text(
                                  AppLocalizations.of(context).arrAlreadyAdded,
                                )
                              : const CupertinoListTileChevron(),
                          onTap:
                              result.alreadyAdded ||
                                  _adding ||
                                  _submissionBlocked
                              ? null
                              : () => _openAddSheet(result),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _search(String query) async {
    final epoch = sessionGeneration;
    if (!_current(epoch) || _adding || _submissionBlocked) return;
    final sequence = ++_queryGeneration;
    if (query.trim().isEmpty) {
      setState(() {
        _results = null;
        _searching = false;
      });
      return;
    }
    setState(() {
      _searching = true;
      _results = null;
      _error = null;
    });
    bool current() => _current(epoch) && sequence == _queryGeneration;
    try {
      final results = await widget.onLookup(query.trim());
      if (current()) setState(() => _results = results);
    } catch (_) {
      if (current()) {
        setState(() {
          _results = null;
          _error = AppLocalizations.of(context).mediaErrorUnreachable;
        });
      }
    } finally {
      if (current()) setState(() => _searching = false);
    }
  }

  Future<void> _openAddSheet(ArrLookupResult result) async {
    final epoch = sessionGeneration;
    if (_adding ||
        _submissionBlocked ||
        !_current(epoch) ||
        _results?.contains(result) != true) {
      return;
    }
    bool current({bool ownModal = false}) =>
        _current(epoch, ownModal: ownModal);
    var submitted = false;
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final profiles = await widget.loadQualityProfiles();
      if (!current()) return;
      final folders = await widget.loadRootFolders();
      if (!current()) return;
      final metadataProfiles = await widget.loadMetadataProfiles?.call();
      if (!mounted || !current()) return;
      if (profiles.isEmpty || folders.isEmpty) {
        setState(
          () => _error = AppLocalizations.of(context).arrMissingConfiguration,
        );
        return;
      }
      if (widget.loadMetadataProfiles != null &&
          (metadataProfiles == null || metadataProfiles.isEmpty)) {
        setState(
          () => _error = AppLocalizations.of(context).arrMissingConfiguration,
        );
        return;
      }

      ArrQualityProfile selectedProfile = profiles.first;
      ArrRootFolder selectedFolder = folders.first;
      ArrMetadataProfile? selectedMetadataProfile = metadataProfiles?.first;

      final route = CupertinoModalPopupRoute<bool>(
        builder: (context) => StatefulBuilder(
          builder: (context, setSheetState) {
            final l10n = AppLocalizations.of(context);
            return CupertinoActionSheet(
              title: Text(result.title),
              message: Text(
                [
                  l10n.arrQualityLine(selectedProfile.name),
                  l10n.arrFolderLine(selectedFolder.path),
                  if (selectedMetadataProfile != null)
                    l10n.arrMetadataLine(selectedMetadataProfile!.name),
                ].join('\n'),
              ),
              actions: [
                for (final profile in profiles)
                  CupertinoActionSheetAction(
                    onPressed: () {
                      if (current(ownModal: true)) {
                        setSheetState(() => selectedProfile = profile);
                      }
                    },
                    child: Text(
                      selectedProfile.id == profile.id
                          ? l10n.arrQualityOptionSelected(profile.name)
                          : l10n.arrQualityLine(profile.name),
                    ),
                  ),
                for (final folder in folders)
                  CupertinoActionSheetAction(
                    onPressed: () {
                      if (current(ownModal: true)) {
                        setSheetState(() => selectedFolder = folder);
                      }
                    },
                    child: Text(
                      selectedFolder.id == folder.id
                          ? l10n.arrFolderOptionSelected(folder.path)
                          : l10n.arrFolderLine(folder.path),
                    ),
                  ),
                if (metadataProfiles != null)
                  for (final profile in metadataProfiles)
                    CupertinoActionSheetAction(
                      onPressed: () {
                        if (current(ownModal: true)) {
                          setSheetState(
                            () => selectedMetadataProfile = profile,
                          );
                        }
                      },
                      child: Text(
                        selectedMetadataProfile?.id == profile.id
                            ? l10n.arrMetadataOptionSelected(profile.name)
                            : l10n.arrMetadataLine(profile.name),
                      ),
                    ),
                CupertinoActionSheetAction(
                  isDefaultAction: true,
                  onPressed: () {
                    if (current(ownModal: true) &&
                        ModalRoute.of(context)?.isCurrent == true) {
                      Navigator.pop(context, true);
                    }
                  },
                  child: Text(l10n.commonAdd),
                ),
              ],
              cancelButton: CupertinoActionSheetAction(
                onPressed: () {
                  if (context.mounted &&
                      ModalRoute.of(context)?.isCurrent == true) {
                    Navigator.pop(context);
                  }
                },
                child: Text(l10n.commonCancel),
              ),
            );
          },
        ),
      );
      _confirmation = route;
      final confirmed = await Navigator.of(context).push(route);
      if (identical(_confirmation, route)) _confirmation = null;
      if (confirmed == true && current()) {
        submitted = true;
        _submissionBlocked = true;
        await widget.onAdd(
          result,
          selectedProfile.id,
          selectedFolder.path,
          selectedMetadataProfile?.id,
        );
        if (mounted && current()) Navigator.of(context).pop(true);
      }
    } catch (error) {
      final rejected =
          error is MediaApiException &&
          error.statusCode != null &&
          error.statusCode! >= 400 &&
          error.statusCode! < 500;
      if (submitted && rejected) _submissionBlocked = false;
      if (mounted && current()) {
        final l10n = AppLocalizations.of(context);
        setState(
          () => _error = switch (error) {
            MediaApiException(statusCode: 401) =>
              l10n.healthAuthenticationRequired,
            MediaApiException(statusCode: 403) => l10n.healthPermissionDenied,
            _ =>
              submitted && !rejected
                  ? l10n.mediaWriteUnknown
                  : l10n.mediaErrorUnreachable,
          },
        );
      }
    } finally {
      if (current()) setState(() => _adding = false);
    }
  }
}

/// Capture the account before navigation; a later confirmation never fetches
/// a replacement client. The container anchor survives a covered parent row.
Future<void> openArrAddScreen({
  required BuildContext context,
  required WidgetRef ref,
  required IntegrationId integration,
  required ProviderListenable<AsyncValue<ArrConfig?>> connectionProvider,
  required ProviderListenable<ArrClient?> clientProvider,
  required String title,
  required String searchHint,
  bool metadata = false,
  VoidCallback? onAdded,
}) async {
  final interaction = AppInteractionScope.maybeRead(context);
  final epoch = interaction?.epoch;
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (!context.mounted ||
      interaction?.active == false ||
      !TickerMode.valuesOf(context).enabled ||
      (lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
      ModalRoute.of(context)?.isCurrent != true) {
    return;
  }
  final config = ref.read(connectionProvider);
  if (config.isLoading || config.hasError || config.value == null) return;
  final client = ref.read(clientProvider);
  if (client == null) return;
  final captured = config.value;
  final container = ProviderScope.containerOf(context, listen: false);
  bool current() {
    try {
      final next = container.read(connectionProvider);
      return interaction?.active != false &&
          interaction?.epoch == epoch &&
          !next.isLoading &&
          !next.hasError &&
          sameHealthConfiguration(captured, next.value) &&
          identical(client, container.read(clientProvider));
    } catch (_) {
      return false;
    }
  }

  final added = await Navigator.of(context).push<bool>(
    CupertinoPageRoute(
      builder: (_) => ArrAddScreen(
        title: title,
        searchHint: searchHint,
        integration: integration,
        connectionProvider: connectionProvider,
        sourceCurrent: current,
        onLookup: client.lookup,
        loadQualityProfiles: client.getQualityProfiles,
        loadRootFolders: client.getRootFolders,
        loadMetadataProfiles: metadata ? client.getMetadataProfiles : null,
        onAdd: (result, profile, folder, metadataProfile) async {
          if (!current()) throw StateError('Selection expired');
          await client.add(
            result: result,
            qualityProfileId: profile,
            rootFolderPath: folder,
            metadataProfileId: metadataProfile,
          );
        },
      ),
    ),
  );
  if (added == true && ref.context.mounted && current()) onAdded?.call();
}
