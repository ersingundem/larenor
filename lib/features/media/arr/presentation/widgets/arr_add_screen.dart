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
  });

  final String title;
  final String searchHint;
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
                onSubmitted: _search,
              ),
            ),
            if (_searching) const CupertinoActivityIndicator(),
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
                          onTap: result.alreadyAdded
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
    setState(() => _searching = true);
    try {
      final results = await widget.onLookup(query.trim());
      if (mounted) setState(() => _results = results);
    } catch (_) {
      if (mounted) setState(() => _results = []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _openAddSheet(ArrLookupResult result) async {
    final profiles = await widget.loadQualityProfiles();
    final folders = await widget.loadRootFolders();
    final metadataProfiles = await widget.loadMetadataProfiles?.call();
    if (!mounted || profiles.isEmpty || folders.isEmpty) return;
    if (widget.loadMetadataProfiles != null &&
        (metadataProfiles == null || metadataProfiles.isEmpty)) {
      return;
    }

    ArrQualityProfile selectedProfile = profiles.first;
    ArrRootFolder selectedFolder = folders.first;
    ArrMetadataProfile? selectedMetadataProfile = metadataProfiles?.first;

    await showCupertinoModalPopup<void>(
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
                  onPressed: () => setSheetState(() => selectedFolder = folder),
                  child: Text(
                    selectedFolder.id == folder.id
                        ? l10n.arrFolderOptionSelected(folder.path)
                        : l10n.arrFolderLine(folder.path),
                  ),
                ),
              if (metadataProfiles != null)
                for (final profile in metadataProfiles)
                  CupertinoActionSheetAction(
                    onPressed: () =>
                        setSheetState(() => selectedMetadataProfile = profile),
                    child: Text(
                      selectedMetadataProfile?.id == profile.id
                          ? l10n.arrMetadataOptionSelected(profile.name)
                          : l10n.arrMetadataLine(profile.name),
                    ),
                  ),
              CupertinoActionSheetAction(
                isDefaultAction: true,
                onPressed: () async {
                  Navigator.pop(context);
                  await widget.onAdd(
                    result,
                    selectedProfile.id,
                    selectedFolder.path,
                    selectedMetadataProfile?.id,
                  );
                  if (mounted) setState(() => _results = null);
                },
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
  }
}
