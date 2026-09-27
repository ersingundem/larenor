import 'package:flutter/cupertino.dart';

import '../data/server_family_memories_controller.dart';
import '../domain/server_family_memory_models.dart';

final class FamilyMemoriesLabels {
  const FamilyMemoriesLabels({
    required this.title,
    required this.searchHint,
    required this.search,
    required this.albums,
    required this.results,
    required this.empty,
    required this.createAlbum,
    required this.albumNameHint,
    required this.personal,
    required this.shared,
    required this.cancel,
    required this.save,
    required this.retry,
    required this.editAlbum,
    required this.reconcile,
    required this.delete,
    required this.deleteConfirm,
    required this.items,
  });

  final String title, searchHint, search, albums, results, empty;
  final String createAlbum,
      albumNameHint,
      personal,
      shared,
      cancel,
      save,
      retry;
  final String editAlbum, reconcile, delete, deleteConfirm;
  final String Function(int count) items;
}

final class ServerFamilyMemoriesScreen extends StatefulWidget {
  const ServerFamilyMemoriesScreen({
    super.key,
    required this.controller,
    required this.labels,
    required this.current,
  });

  final ServerFamilyMemoriesController controller;
  final FamilyMemoriesLabels labels;
  final bool Function() current;

  @override
  State<ServerFamilyMemoriesScreen> createState() =>
      _ServerFamilyMemoriesScreenState();
}

class _ServerFamilyMemoriesScreenState
    extends State<ServerFamilyMemoriesScreen> {
  final _query = TextEditingController();
  final Set<String> _selected = {};
  String? _sourceAlbumId;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.load(current: widget.current);
    });
  }

  void _changed() {
    final allowed =
        widget.controller.snapshot?.binding.allowedAlbumIds ?? const [];
    if (_sourceAlbumId == null || !allowed.contains(_sourceAlbumId)) {
      _sourceAlbumId = allowed.isEmpty ? null : allowed.first;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final albumId = _sourceAlbumId;
    if (albumId == null || _query.text.trim().isEmpty) return;
    final binding = widget.controller.snapshot?.binding;
    if (binding == null) return;
    _selected.clear();
    await widget.controller.search(
      serviceId: binding.serviceId,
      serviceRevision: binding.serviceRevision,
      query: _query.text.trim(),
      albumIds: [albumId],
      current: widget.current,
    );
  }

  Future<void> _save(FamilyMemoryAlbum album) async {
    final byId = {
      for (final item in widget.controller.searchResults) item.assetId: item,
    };
    final additions = _selected.map((id) {
      final item = byId[id]!;
      return FamilyMemorySelection(
        item.assetId,
        item.sourceAlbumId,
        item.sourceEtag,
      );
    });
    final merged = <String, FamilyMemorySelection>{
      for (final item in album.assets) item.assetId: item,
      for (final item in additions) item.assetId: item,
    };
    await widget.controller.saveSelections(
      album,
      merged.values.toList(growable: false),
      current: widget.current,
    );
    _selected.clear();
  }

  Future<void> _createAlbum() async {
    final name = TextEditingController();
    var shared = false;
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => CupertinoAlertDialog(
          title: Text(widget.labels.createAlbum),
          content: Column(
            children: [
              const SizedBox(height: 12),
              CupertinoTextField(
                controller: name,
                placeholder: widget.labels.albumNameHint,
                maxLength: 120,
              ),
              const SizedBox(height: 12),
              CupertinoSlidingSegmentedControl<bool>(
                groupValue: shared,
                children: {
                  false: Text(widget.labels.personal),
                  true: Text(widget.labels.shared),
                },
                onValueChanged: (value) {
                  if (value != null) setDialogState(() => shared = value);
                },
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: Text(widget.labels.cancel),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(context, true),
              child: Text(widget.labels.save),
            ),
          ],
        ),
      ),
    );
    final title = name.text.trim();
    name.dispose();
    if (accepted != true || title.isEmpty) return;
    final accountId = widget.controller.snapshot?.authority.accountId;
    if (accountId == null) return;
    await widget.controller.createAlbum(
      title: title,
      visibility: shared ? 'shared' : 'personal',
      memberIds: shared ? widget.controller.snapshot!.memberIds : [accountId],
      serviceId: widget.controller.snapshot!.binding.serviceId,
      serviceRevision: widget.controller.snapshot!.binding.serviceRevision,
      current: widget.current,
    );
  }

  Future<void> _manageAlbum(FamilyMemoryAlbum album) async {
    if (widget.controller.busy) return;
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(album.title),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'edit'),
            child: Text(widget.labels.editAlbum),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'reconcile'),
            child: Text(widget.labels.reconcile),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, 'delete'),
            child: Text(widget.labels.delete),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.labels.cancel),
        ),
      ),
    );
    if (!mounted || !widget.current()) return;
    if (action == 'reconcile') {
      await widget.controller.reconcileAlbum(album, current: widget.current);
      return;
    }
    if (action == 'delete') {
      final accepted = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(widget.labels.delete),
          content: Text(widget.labels.deleteConfirm),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: Text(widget.labels.cancel),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(context, true),
              child: Text(widget.labels.delete),
            ),
          ],
        ),
      );
      if (accepted == true && mounted && widget.current()) {
        await widget.controller.deleteAlbum(album, current: widget.current);
      }
      return;
    }
    if (action != 'edit') return;
    final name = TextEditingController(text: album.title);
    var shared = album.visibility == 'shared';
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => CupertinoAlertDialog(
          title: Text(widget.labels.editAlbum),
          content: Column(
            children: [
              const SizedBox(height: 12),
              CupertinoTextField(controller: name, maxLength: 120),
              const SizedBox(height: 12),
              CupertinoSlidingSegmentedControl<bool>(
                groupValue: shared,
                children: {
                  false: Text(widget.labels.personal),
                  true: Text(widget.labels.shared),
                },
                onValueChanged: (value) {
                  if (value != null) setDialogState(() => shared = value);
                },
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: Text(widget.labels.cancel),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(context, true),
              child: Text(widget.labels.save),
            ),
          ],
        ),
      ),
    );
    final title = name.text.trim();
    name.dispose();
    if (accepted != true || title.isEmpty || !mounted || !widget.current()) {
      return;
    }
    final members = widget.controller.snapshot?.memberIds;
    if (members == null) return;
    await widget.controller.updateAlbum(
      album,
      title: title,
      visibility: shared ? 'shared' : 'personal',
      memberIds: shared ? members : [album.ownerId],
      current: widget.current,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final albums = controller.snapshot?.albums ?? const <FamilyMemoryAlbum>[];
    final sourceAlbums =
        controller.snapshot?.binding.allowedAlbumIds ?? const <String>[];
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.labels.title),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: controller.busy ? null : _createAlbum,
          child: const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            CupertinoSearchTextField(
              controller: _query,
              placeholder: widget.labels.searchHint,
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 8),
            if (sourceAlbums.length > 1)
              CupertinoSlidingSegmentedControl<String>(
                groupValue: _sourceAlbumId,
                children: {
                  for (final id in sourceAlbums)
                    id: Text(id, overflow: TextOverflow.ellipsis),
                },
                onValueChanged: (value) =>
                    setState(() => _sourceAlbumId = value),
              ),
            CupertinoButton.filled(
              onPressed: controller.busy ? null : _search,
              child: Text(widget.labels.search),
            ),
            if (controller.failure != null)
              CupertinoButton(
                onPressed: controller.busy
                    ? null
                    : () => controller.load(current: widget.current),
                child: Text(widget.labels.retry),
              ),
            if (controller.busy) const CupertinoActivityIndicator(),
            if (controller.searchResults.isNotEmpty) ...[
              _heading(widget.labels.results),
              for (final item in controller.searchResults)
                CupertinoListTile(
                  title: Text(item.fileName),
                  subtitle: Text(item.takenAt),
                  trailing: Icon(
                    _selected.contains(item.assetId)
                        ? CupertinoIcons.check_mark_circled_solid
                        : CupertinoIcons.circle,
                  ),
                  onTap: () => setState(() {
                    if (!_selected.add(item.assetId)) {
                      _selected.remove(item.assetId);
                    }
                  }),
                ),
            ],
            _heading(widget.labels.albums),
            if (albums.isEmpty) Text(widget.labels.empty),
            for (final album in albums)
              CupertinoListTile(
                title: Text(album.title),
                subtitle: Text(widget.labels.items(album.assets.length)),
                onTap: () => _manageAlbum(album),
                trailing: _selected.isEmpty
                    ? null
                    : CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: controller.busy ? null : () => _save(album),
                        child: Text(widget.labels.save),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _heading(String value) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(
      value,
      style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
    ),
  );
}
