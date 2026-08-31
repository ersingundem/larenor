import 'package:flutter/cupertino.dart';

import '../../data/models/arr_lookup_result.dart';
import '../../data/models/arr_picker_options.dart';

/// Shared "search and add" flow for Sonarr/Radarr: lookup → pick a result →
/// pick quality profile + root folder → confirm. Parameterized entirely by
/// callbacks so the same widget drives both services.
class ArrAddScreen extends StatefulWidget {
  const ArrAddScreen({
    super.key,
    required this.title,
    required this.searchHint,
    required this.onLookup,
    required this.loadQualityProfiles,
    required this.loadRootFolders,
    required this.onAdd,
  });

  final String title;
  final String searchHint;
  final Future<List<ArrLookupResult>> Function(String term) onLookup;
  final Future<List<ArrQualityProfile>> Function() loadQualityProfiles;
  final Future<List<ArrRootFolder>> Function() loadRootFolders;
  final Future<void> Function(
    ArrLookupResult result,
    int qualityProfileId,
    String rootFolderPath,
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
                  ? const Center(child: Text('Search to add something new'))
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
                              ? const Text('Added')
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
    if (!mounted || profiles.isEmpty || folders.isEmpty) return;

    ArrQualityProfile selectedProfile = profiles.first;
    ArrRootFolder selectedFolder = folders.first;

    await showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => CupertinoActionSheet(
          title: Text(result.title),
          message: Text(
            'Quality: ${selectedProfile.name}\nFolder: ${selectedFolder.path}',
          ),
          actions: [
            for (final profile in profiles)
              CupertinoActionSheetAction(
                onPressed: () => setSheetState(() => selectedProfile = profile),
                child: Text(
                  '${selectedProfile.id == profile.id ? '✓ ' : ''}Quality: ${profile.name}',
                ),
              ),
            for (final folder in folders)
              CupertinoActionSheetAction(
                onPressed: () => setSheetState(() => selectedFolder = folder),
                child: Text(
                  '${selectedFolder.id == folder.id ? '✓ ' : ''}Folder: ${folder.path}',
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
                );
                if (mounted) setState(() => _results = null);
              },
              child: const Text('Add'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ),
      ),
    );
  }
}
