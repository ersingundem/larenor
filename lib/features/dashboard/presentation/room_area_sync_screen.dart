import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../auth/providers/auth_providers.dart';
import '../domain/dashboard_room.dart';
import '../providers/dashboard_providers.dart';
import '../providers/room_area_sync_providers.dart';
import 'dashboard_edit_guard.dart';

/// Every displayed diff comes from a complete successful read. Applying it
/// only writes the local dashboard after the controller rechecks the source.
class RoomAreaSyncScreen extends ConsumerStatefulWidget {
  const RoomAreaSyncScreen({super.key, required this.roomId});
  final String roomId;
  @override
  ConsumerState<RoomAreaSyncScreen> createState() => _RoomAreaSyncScreenState();
}

class _RoomAreaSyncScreenState extends DashboardEditState<RoomAreaSyncScreen> {
  String? _areaId;
  RoomAreaSyncPreview? _preview;
  int? _previewGeneration;
  bool _busy = false;
  String? _message;
  Route<bool>? _dialog;

  @override
  void invalidateDashboardInteraction() {
    _preview = null;
    _areaId = null;
    _previewGeneration = null;
    _message = null;
    final dialog = _dialog;
    _dialog = null;
    if (dialog?.isActive == true) dialog!.navigator?.removeRoute(dialog);
  }

  Future<void> _previewChanges(String areaId) async {
    final generation = interactionGeneration;
    if (_busy || _dialog != null || !interactionCurrent(generation)) return;
    setState(() {
      _busy = true;
      _preview = null;
      _message = null;
    });
    try {
      final preview = await ref
          .read(roomAreaSyncControllerProvider)
          .preview(roomId: widget.roomId, areaId: areaId);
      if (!interactionCurrent(generation)) return;
      setState(() {
        _preview = preview;
        _previewGeneration = generation;
      });
    } catch (_) {
      if (interactionCurrent(generation)) {
        setState(() => _message = AppLocalizations.of(context).roomSyncFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _previewCurrent(RoomAreaSyncPreview preview) {
    if (_previewGeneration == null ||
        !interactionCurrent(_previewGeneration!)) {
      return false;
    }
    final source = ref.read(roomAreaSyncSourceProvider);
    final layout = ref.read(dashboardLayoutProvider);
    return !source.isLoading &&
        !source.hasError &&
        identical(source.value, preview.source) &&
        !layout.isLoading &&
        !layout.hasError &&
        layout.value == preview.layout;
  }

  Future<void> _apply(RoomAreaSyncPreview preview) async {
    if (_busy ||
        _dialog != null ||
        !_previewCurrent(preview) ||
        preview.change.missingArea) {
      return;
    }
    final generation = interactionGeneration;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref.read(roomAreaSyncControllerProvider).apply(preview);
      if (interactionCurrent(generation)) {
        setState(() {
          _preview = null;
          _message = AppLocalizations.of(context).roomSyncApplied;
        });
      }
    } catch (_) {
      if (interactionCurrent(generation)) {
        setState(() {
          _preview = null;
          _message = AppLocalizations.of(context).roomSyncStale;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unbind(DashboardRoom room) async {
    final generation = interactionGeneration;
    if (_busy || _dialog != null || !interactionCurrent(generation)) return;
    final route = CupertinoDialogRoute<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(AppLocalizations.of(context).roomSyncUnbind),
        content: Text(AppLocalizations.of(context).roomSyncUnbindConfirm),
        actions: [
          CupertinoDialogAction(
            onPressed: () => closeDashboardModal(context, false),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('room-sync-confirm-unbind'),
            onPressed: () {
              if (context.mounted &&
                  ModalRoute.of(context)?.isCurrent == true) {
                closeDashboardModal(context, true);
              }
            },
            child: Text(AppLocalizations.of(context).roomSyncUnbind),
          ),
        ],
      ),
    );
    _dialog = route;
    final confirmed = await Navigator.of(context).push<bool>(route);
    if (identical(_dialog, route)) _dialog = null;
    if (confirmed != true || !interactionCurrent(generation)) return;
    final currentRoom = ref
        .read(dashboardLayoutProvider)
        .value
        ?.rooms
        .where((item) => item.id == room.id)
        .firstOrNull;
    if (currentRoom != room) return;
    setState(() => _busy = true);
    try {
      await ref.read(dashboardLayoutProvider.notifier).detachRoomArea(room.id);
      if (interactionCurrent(generation)) {
        setState(() {
          _preview = null;
          _areaId = null;
          _message = null;
        });
      }
    } catch (_) {
      if (interactionCurrent(generation)) {
        setState(
          () => _message = AppLocalizations.of(context).dashboardEditFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(connectionConfigProvider);
    watchDashboardAccount();
    final l10n = AppLocalizations.of(context);
    final layout = ref.watch(dashboardLayoutProvider);
    final source = ref.watch(roomAreaSyncSourceProvider);
    ref.watch(roomAreaSyncControllerProvider);
    final room = layout.value?.rooms
        .where((room) => room.id == widget.roomId)
        .firstOrNull;
    final mismatch = room != null && !roomMatchesCurrentServer(ref, room);
    final bound = room?.areaBinding;
    final selected = _areaId ?? bound?.areaId;
    final generation = interactionGeneration;
    final preview = _preview;
    final validPreview = preview != null && _previewCurrent(preview);
    final areas = !source.isLoading && !source.hasError
        ? source.value?.areas.values.toList() ?? []
        : [];
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.roomSyncTitle)),
      child: !foreground
          ? const SizedBox.expand()
          : SafeArea(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (room != null)
                            Text(room.name, style: AppText.title2),
                          const SizedBox(height: 12),
                          Text(l10n.roomSyncLocalOnly),
                          if (mismatch)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(l10n.roomSyncMismatch),
                            ),
                          if (_message != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Semantics(
                                liveRegion: true,
                                child: Text(_message!),
                              ),
                            ),
                          if (room == null)
                            Text(l10n.navigationDestinationMissing),
                          if (bound != null) ...[
                            const SizedBox(height: 12),
                            Text(bound.sourceName, style: AppText.headline),
                            CupertinoButton(
                              key: const ValueKey('room-sync-unbind'),
                              onPressed: _busy
                                  ? null
                                  : dashboardAction(() => _unbind(room!)),
                              child: Text(l10n.roomSyncUnbind),
                            ),
                          ],
                          if (source.isLoading)
                            const CupertinoActivityIndicator(),
                          if (source.hasError) Text(l10n.roomSyncFailed),
                          if (!mismatch && room != null) ...[
                            if (bound == null)
                              Text(
                                l10n.roomSyncPickArea,
                                style: AppText.headline,
                              ),
                            if (bound != null || selected != null)
                              CupertinoButton.filled(
                                key: const ValueKey('room-sync-preview'),
                                onPressed:
                                    _busy || source.isLoading || source.hasError
                                    ? null
                                    : dashboardAction(
                                        () => _previewChanges(selected!),
                                      ),
                                child: Text(l10n.roomSyncPreview),
                              ),
                          ],
                          CupertinoButton(
                            key: const ValueKey('room-sync-refresh'),
                            onPressed: _busy
                                ? null
                                : dashboardAction(() {
                                    setState(() => _preview = null);
                                    ref.invalidate(roomAreaSyncSourceProvider);
                                  }),
                            child: Text(l10n.commonRetry),
                          ),
                          if (preview != null && !validPreview)
                            Text(l10n.roomSyncStale),
                        ],
                      ),
                    ),
                  ),
                  if (bound == null && !mismatch)
                    SliverList.builder(
                      itemCount: areas.length,
                      itemBuilder: (context, index) {
                        final area = areas[index];
                        return CupertinoListTile(
                          key: ValueKey('room-sync-area-${area.areaId}'),
                          title: Text(area.name),
                          trailing: selected == area.areaId
                              ? const Icon(CupertinoIcons.check_mark)
                              : null,
                          onTap: _busy
                              ? null
                              : () {
                                  if (interactionCurrent(generation)) {
                                    setState(() {
                                      _areaId = area.areaId;
                                      _preview = null;
                                    });
                                  }
                                },
                        );
                      },
                    ),
                  if (preview != null && validPreview) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (preview.change.missingArea)
                              Text(l10n.roomSyncMissingArea),
                            if (!preview.change.hasChanges &&
                                !preview.change.missingArea)
                              Text(l10n.roomSyncNoChanges),
                            if (preview.change.renamed)
                              Text(
                                l10n.roomSyncRename(preview.change.after.name),
                              ),
                            Text(
                              l10n.roomSyncAdded(preview.change.added.length),
                              style: AppText.headline,
                            ),
                            Text(
                              l10n.roomSyncRemoved(
                                preview.change.removed.length,
                              ),
                            ),
                            Text(
                              l10n.roomSyncHeld(
                                preview.change.heldUnknown.length,
                              ),
                            ),
                            const SizedBox(height: 12),
                            CupertinoButton.filled(
                              key: const ValueKey('room-sync-apply'),
                              onPressed:
                                  _busy ||
                                      preview.change.missingArea ||
                                      !preview.change.hasChanges
                                  ? null
                                  : () => _apply(preview),
                              child: Text(l10n.roomSyncApply),
                            ),
                          ],
                        ),
                      ),
                    ),
                    for (final group in [
                      (
                        ids: preview.change.added,
                        icon: CupertinoIcons.add_circled,
                      ),
                      (
                        ids: preview.change.removed,
                        icon: CupertinoIcons.minus_circle,
                      ),
                      (
                        ids: preview.change.heldUnknown,
                        icon: CupertinoIcons.question_circle,
                      ),
                    ])
                      SliverList.builder(
                        itemCount: group.ids.length,
                        itemBuilder: (context, index) {
                          final id = group.ids[index];
                          return CupertinoListTile(
                            leading: Icon(group.icon),
                            title: Text(
                              preview.source.entities[id]?.friendlyName ?? id,
                            ),
                            subtitle: Text(id),
                          );
                        },
                      ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ],
              ),
            ),
    );
  }
}
