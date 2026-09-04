import 'package:flutter/cupertino.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../data/models/arr_lookup_result.dart';
import '../../data/models/arr_picker_options.dart';

/// Shared "search and add" flow for Sonarr/Radarr/Lidarr/Readarr: lookup →
/// pick a result → pick quality profile + root folder (+ metadata profile
/// for Lidarr/Readarr) → confirm. Parameterized entirely by callbacks so
/// the same widget drives all four services.
class ArrAddScreen extends StatefulWidget {
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
  });

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
  State<ArrAddScreen> createState() => _ArrAddScreenState();
}

class _ArrAddScreenState extends State<ArrAddScreen> {
  List<ArrLookupResult>? _results;
  bool _searching = false;
  bool _adding = false;
  String? _error;
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    if (widget.initialQuery != null) _search(widget.initialQuery!);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(widget.title)),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoSearchTextField(
                placeholder: widget.searchHint,
                controller: _controller,
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
              child: _results == null
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
                          onTap: result.alreadyAdded || _adding
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
    if (query.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await widget.onLookup(query.trim());
      if (mounted) setState(() => _results = results);
    } catch (_) {
      if (mounted) {
        setState(() {
          _results = [];
          _error = AppLocalizations.of(context).mediaErrorUnreachable;
        });
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _openAddSheet(ArrLookupResult result) async {
    if (_adding) return;
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      final profiles = await widget.loadQualityProfiles();
      final folders = await widget.loadRootFolders();
      final metadataProfiles = await widget.loadMetadataProfiles?.call();
      if (!mounted) return;
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

      final confirmed = await showCupertinoModalPopup<bool>(
        context: context,
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
                    onPressed: () =>
                        setSheetState(() => selectedProfile = profile),
                    child: Text(
                      selectedProfile.id == profile.id
                          ? l10n.arrQualityOptionSelected(profile.name)
                          : l10n.arrQualityLine(profile.name),
                    ),
                  ),
                for (final folder in folders)
                  CupertinoActionSheetAction(
                    onPressed: () =>
                        setSheetState(() => selectedFolder = folder),
                    child: Text(
                      selectedFolder.id == folder.id
                          ? l10n.arrFolderOptionSelected(folder.path)
                          : l10n.arrFolderLine(folder.path),
                    ),
                  ),
                if (metadataProfiles != null)
                  for (final profile in metadataProfiles)
                    CupertinoActionSheetAction(
                      onPressed: () => setSheetState(
                        () => selectedMetadataProfile = profile,
                      ),
                      child: Text(
                        selectedMetadataProfile?.id == profile.id
                            ? l10n.arrMetadataOptionSelected(profile.name)
                            : l10n.arrMetadataLine(profile.name),
                      ),
                    ),
                CupertinoActionSheetAction(
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(l10n.commonAdd),
                ),
              ],
              cancelButton: CupertinoActionSheetAction(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.commonCancel),
              ),
            );
          },
        ),
      );
      if (confirmed == true) {
        await widget.onAdd(
          result,
          selectedProfile.id,
          selectedFolder.path,
          selectedMetadataProfile?.id,
        );
        if (mounted) Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context).mediaErrorUnreachable,
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }
}
