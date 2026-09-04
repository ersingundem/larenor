import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/icon_sizes.dart';
import '../../../shared/theme/radii.dart';
import '../../../shared/theme/spacing.dart';
import '../../../shared/theme/typography.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/data/ws_client.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../settings/data/app_service.dart';
import '../../settings/providers/enabled_services_providers.dart';
import '../domain/dashboard_layout.dart';
import '../domain/dashboard_room.dart';
import '../domain/home_domains.dart';
import '../domain/tile_config.dart';
import '../providers/dashboard_providers.dart';
import '../providers/home_dashboard_providers.dart';
import 'entity_multi_picker_screen.dart';
import 'entity_picker_screen.dart';
import 'tile_kinds.dart';
import 'widgets/home_surface.dart';
import 'tiles/home_accessory_tile.dart';
import 'tiles/tile_registry.dart';
import '../../../shared/widgets/section_header.dart';

String _generateTileId() => DateTime.now().microsecondsSinceEpoch.toString();

/// The dashboard, modelled on Apple's Home app but assembled by hand:
/// rooms the user created, holding devices they picked. Home Assistant
/// supplies live state for those entities; it doesn't decide what appears.
/// Nothing is placed or resized by hand — the grid arranges itself.
class HomeDashboardScreen extends ConsumerStatefulWidget {
  const HomeDashboardScreen({super.key});

  @override
  ConsumerState<HomeDashboardScreen> createState() =>
      _HomeDashboardScreenState();
}

class _HomeDashboardScreenState extends ConsumerState<HomeDashboardScreen> {
  /// `null` is the "All" chip.
  HomeCategory? _category;
  String? _selectedRoom;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final layoutAsync = ref.watch(dashboardLayoutProvider);
    final connectionStatus = ref.watch(haConnectionStatusProvider);
    final entitiesAsync = ref.watch(entitiesProvider);

    final layout = layoutAsync.value;
    final rooms = layout?.rooms ?? const <DashboardRoom>[];
    final selectedRoom = rooms.where((r) => r.id == _selectedRoom).firstOrNull;
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final hasMedia = _hasMediaServices();

    final content = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        CupertinoSliverNavigationBar(
          backgroundColor: CupertinoColors.systemBackground
              .resolveFrom(context)
              .withValues(alpha: 0.28),
          border: null,
          largeTitle: Text(selectedRoom?.name ?? l10n.homeTitle),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _showAddMenu,
                child: Semantics(
                  label: l10n.commonAdd,
                  child: const Icon(CupertinoIcons.add_circled),
                ),
              ),
              if (!wide && hasMedia)
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => context.push('/media'),
                  child: Semantics(
                    label: l10n.homeCategoryMedia,
                    child: const Icon(CupertinoIcons.play_rectangle),
                  ),
                ),
              if (!wide)
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => context.push('/settings'),
                  child: Semantics(
                    label: l10n.settingsScreenTitle,
                    child: const Icon(CupertinoIcons.settings),
                  ),
                ),
            ],
          ),
        ),
        CupertinoSliverRefreshControl(onRefresh: _refresh),
        SliverToBoxAdapter(
          child: _ConnectionBanner(
            status: connectionStatus.value,
            entitiesError: entitiesAsync.hasError
                ? entitiesAsync.error.toString()
                : null,
            onRetry: _refresh,
          ),
        ),
        ...layoutAsync.when(
          loading: () => const [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CupertinoActivityIndicator()),
            ),
          ],
          error: (error, _) => [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.dashboardLoadError(error.toString()),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ],
          data: _buildSections,
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );

    return CupertinoPageScaffold(
      child: HomeWallpaper(
        child: Row(
          children: [
            if (wide)
              HomeSidebar(
                rooms: rooms,
                selectedRoom: selectedRoom?.id,
                onSelectRoom: (id) => setState(() => _selectedRoom = id),
                onAddRoom: _promptAddRoom,
                onSettings: () => context.push('/settings'),
                onMedia: hasMedia ? () => context.push('/media') : null,
              ),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    ref.invalidate(haWebSocketClientProvider);
    try {
      ref.invalidate(entitiesProvider);
      await ref.read(entitiesProvider.future);
    } catch (_) {
      // The connection banner renders the provider error with a retry action.
    }
  }

  /// The dashboard is what the user assembled: rooms they made, holding
  /// devices they picked. Home Assistant supplies live state for those
  /// entities and nothing else — it no longer decides what's on screen.
  List<Widget> _buildSections(DashboardLayout layout) {
    final l10n = AppLocalizations.of(context);
    final entities = ref.watch(entitiesProvider).value ?? const {};
    final enabledServices =
        ref.watch(enabledServicesProvider).value ?? const <AppService>{};

    List<HaEntity> resolve(Iterable<String> ids) => _filtered([
      for (final id in ids.toSet())
        if (!layout.hiddenEntityIds.contains(id))
          entities[id] ?? HaEntity(entityId: id, state: 'unavailable'),
    ]);
    final selectedRoom = layout.rooms
        .where((r) => r.id == _selectedRoom)
        .firstOrNull;
    final allVisible = <String, HaEntity>{
      for (final id in {
        ...layout.favoriteEntityIds,
        for (final room in layout.rooms) ...room.entityIds,
      })
        if (!layout.hiddenEntityIds.contains(id))
          id: entities[id] ?? HaEntity(entityId: id, state: 'unavailable'),
    };

    final favourites = resolve(layout.favoriteEntityIds);
    final rooms = [
      for (final room in layout.rooms)
        if (selectedRoom == null || room.id == selectedRoom.id)
          (room: room, entities: resolve(room.entityIds)),
    ];

    if (layout.rooms.isEmpty &&
        layout.tiles.isEmpty &&
        enabledServices.isEmpty &&
        favourites.isEmpty) {
      return [_emptyState(l10n)];
    }

    return [
      SliverToBoxAdapter(
        child: HomeOverview(entities: allVisible.values.toList()),
      ),
      if (layout.rooms.isNotEmpty && MediaQuery.sizeOf(context).width < 1000)
        SliverToBoxAdapter(child: _roomStrip(layout.rooms, selectedRoom?.id)),
      if (rooms.isNotEmpty || favourites.isNotEmpty)
        SliverToBoxAdapter(child: _categoryStrip()),
      if (favourites.isNotEmpty && selectedRoom == null) ...[
        _sectionHeader(l10n.homeFavorites),
        _accessoryGrid(favourites),
      ],
      if (_category != null &&
          rooms.every((entry) => entry.entities.isEmpty) &&
          (favourites.isEmpty || selectedRoom != null))
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.homeNoCategoryDevices),
          ),
        ),
      for (final entry in rooms)
        if (_category == null || entry.entities.isNotEmpty) ...[
          _sectionHeader(entry.room.name, room: entry.room),
          if (entry.entities.isEmpty)
            SliverToBoxAdapter(child: _roomPlaceholder(l10n, entry.room))
          else
            _accessoryGrid(entry.entities, room: entry.room),
        ],
      // Services and hand-added widgets aren't accessories, so the
      // category chips (which describe accessory kinds) don't filter them.
      if (_category == null && selectedRoom == null) ...[
        if (enabledServices.isNotEmpty) ...[
          _sectionHeader(l10n.homeServices),
          _tileGrid([
            for (final service in AppService.values)
              if (enabledServices.contains(service))
                TileConfig(
                  id: 'service-${service.name}',
                  type: serviceTileTypes[service]!,
                  x: 0,
                  y: 0,
                  width: 3,
                  height: 2,
                ),
          ]),
        ],
        if (layout.tiles.isNotEmpty) ...[
          _sectionHeader(l10n.homeWidgets),
          _tileGrid(layout.tiles, dismissible: true),
        ],
      ],
    ];
  }

  Widget _emptyState(AppLocalizations l10n) => SliverFillRemaining(
    hasScrollBody: false,
    child: Padding(
      padding: Insets.emptyState,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.square_grid_2x2,
            size: IconSizes.hero,
            color: CupertinoColors.tertiaryLabel.resolveFrom(context),
          ),
          const SizedBox(height: Gap.lg),
          Text(l10n.dashboardNoRoomsTitle, style: AppText.emptyStateTitle),
          const SizedBox(height: Gap.sm),
          Text(
            l10n.dashboardNoRoomsMessage,
            textAlign: TextAlign.center,
            style: AppText.emptyStateBody.copyWith(
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(height: Gap.xl),
          CupertinoButton.filled(
            onPressed: _promptAddRoom,
            child: Text(l10n.dashboardAddRoom),
          ),
          const SizedBox(height: Gap.sm),
          CupertinoButton(
            onPressed: _importHaAreas,
            child: Text(l10n.roomImportAreas),
          ),
        ],
      ),
    ),
  );

  Widget _roomPlaceholder(AppLocalizations l10n, DashboardRoom room) => Padding(
    padding: const EdgeInsets.fromLTRB(
      Insets.pageGutter,
      0,
      Insets.pageGutter,
      Gap.sm,
    ),
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: () => _addDevicesToRoom(room),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.add_circled, size: IconSizes.caption),
          const SizedBox(width: Gap.xs),
          Text(l10n.roomAddDevices, style: AppText.subhead),
        ],
      ),
    ),
  );

  /// The media hub only makes sense once at least one of the services it
  /// draws on is switched on — otherwise it would open onto an empty
  /// screen, so the button stays hidden.
  bool _hasMediaServices() {
    final enabled =
        ref.watch(enabledServicesProvider).value ?? const <AppService>{};
    return enabled.contains(AppService.jellyfin) ||
        enabled.contains(AppService.jellyseerr) ||
        enabled.contains(AppService.sonarr) ||
        enabled.contains(AppService.radarr);
  }

  List<HaEntity> _filtered(List<HaEntity> entities) {
    final category = _category;
    if (category == null) return entities;
    return entities.where((e) => homeCategoryForEntity(e) == category).toList();
  }

  Widget _roomStrip(List<DashboardRoom> rooms, String? selected) {
    final l10n = AppLocalizations.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        children: [
          for (final entry in <String?, String>{
            null: l10n.homeRoomAll,
            for (final room in rooms) room.id: room.name,
          }.entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                onPressed: () => setState(() => _selectedRoom = entry.key),
                child: Text(
                  entry.value,
                  style: AppText.subhead.copyWith(
                    fontWeight: selected == entry.key
                        ? FontWeight.w700
                        : FontWeight.w400,
                    color: selected == entry.key
                        ? CupertinoColors.label.resolveFrom(context)
                        : CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _categoryStrip() {
    final l10n = AppLocalizations.of(context);
    final labels = <HomeCategory?, String>{
      null: l10n.homeCategoryAll,
      HomeCategory.lights: l10n.homeCategoryLights,
      HomeCategory.climate: l10n.homeCategoryClimate,
      HomeCategory.security: l10n.homeCategorySecurity,
      HomeCategory.media: l10n.homeCategoryMedia,
    };

    // Height comes from the chips themselves rather than a literal — the
    // strip previously capped them at 36pt, which their own padding plus
    // label already filled at the default text size and overflowed one
    // Dynamic Type step up.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: Insets.page,
        child: Row(
          children: [
            for (final entry in labels.entries)
              Padding(
                padding: const EdgeInsets.only(right: Gap.sm),
                child: _CategoryChip(
                  label: entry.value,
                  icon: switch (entry.key) {
                    HomeCategory.lights => CupertinoIcons.lightbulb_fill,
                    HomeCategory.climate => CupertinoIcons.thermometer,
                    HomeCategory.security =>
                      CupertinoIcons.shield_lefthalf_fill,
                    HomeCategory.media => CupertinoIcons.play_rectangle_fill,
                    _ => CupertinoIcons.square_grid_2x2_fill,
                  },
                  selected: _category == entry.key,
                  onTap: () => setState(() => _category = entry.key),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, {DashboardRoom? room}) =>
      SliverSectionHeader(
        title: title,
        trailing: room == null
            ? null
            : CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: const Size.square(IconSizes.minTapTarget),
                onPressed: () => _showRoomMenu(room),
                child: const Icon(
                  CupertinoIcons.ellipsis_circle,
                  size: IconSizes.body,
                ),
              ),
      );

  /// One shared grid geometry for every section, so the whole page reads as
  /// a single uniform layout the way Apple Home's does — two columns on a
  /// phone, more on the tablet, with no per-tile sizing.
  /// `mainAxisExtent` rather than `childAspectRatio`: the cell has to be
  /// as tall as its contents need at the current text scale, not a fixed
  /// proportion of its width.
  SliverGridDelegate _gridDelegate(BuildContext context) =>
      SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 210,
        mainAxisSpacing: Gap.md,
        crossAxisSpacing: Gap.md,
        mainAxisExtent: HomeAccessoryTile.heightFor(context),
      );

  Widget _accessoryGrid(List<HaEntity> entities, {DashboardRoom? room}) =>
      SliverPadding(
        padding: Insets.page,
        sliver: SliverGrid(
          gridDelegate: _gridDelegate(context),
          delegate: SliverChildBuilderDelegate(
            (context, index) =>
                HomeAccessoryTile(entity: entities[index], roomId: room?.id),
            childCount: entities.length,
          ),
        ),
      );

  Widget _tileGrid(List<TileConfig> tiles, {bool dismissible = false}) =>
      SliverPadding(
        padding: Insets.page,
        sliver: SliverGrid(
          gridDelegate: _gridDelegate(context),
          delegate: SliverChildBuilderDelegate((context, index) {
            final tile = tiles[index];
            final content = ClipRRect(
              borderRadius: Radii.brLarge,
              child: buildTileContent(tile),
            );
            if (!dismissible) return content;
            return GestureDetector(
              onLongPress: () => _confirmRemoveWidget(tile),
              child: content,
            );
          }, childCount: tiles.length),
        ),
      );

  Future<void> _confirmRemoveWidget(TileConfig tile) async {
    final l10n = AppLocalizations.of(context);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(tile.title ?? tile.url ?? l10n.homeWidgets),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(sheetContext).pop();
              ref.read(dashboardLayoutProvider.notifier).removeTile(tile.id);
            },
            child: Text(l10n.commonRemove),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
  }

  Future<void> _showAddMenu() async {
    final l10n = AppLocalizations.of(context);
    final layout = ref.read(dashboardLayoutProvider).value;
    final hasRooms = layout?.rooms.isNotEmpty ?? false;

    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              _promptAddRoom();
            },
            child: Text(l10n.dashboardAddRoom),
          ),
          if (hasRooms)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _pickRoomThenAddDevices();
              },
              child: Text(l10n.roomAddDevices),
            ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              _importHaAreas();
            },
            child: Text(l10n.roomImportAreas),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              _addWebsite();
            },
            child: Text(l10n.homeAddWebsite),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              _addHistoryGraph();
            },
            child: Text(l10n.homeAddHistory),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
  }

  Future<String?> _promptName({required String title, String? initial}) async {
    final controller = TextEditingController(text: initial);
    final l10n = AppLocalizations.of(context);
    return showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: Gap.md),
          child: CupertinoTextField(
            controller: controller,
            autofocus: true,
            placeholder: l10n.roomNamePlaceholder,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
  }

  Future<void> _promptAddRoom() async {
    final name = await _promptName(
      title: AppLocalizations.of(context).roomAddTitle,
    );
    if (name == null || name.isEmpty || !mounted) return;
    await ref.read(dashboardLayoutProvider.notifier).addRoom(name);
  }

  Future<void> _showRoomMenu(DashboardRoom room) async {
    final l10n = AppLocalizations.of(context);
    final rooms =
        ref.read(dashboardLayoutProvider).value?.rooms ??
        const <DashboardRoom>[];
    final index = rooms.indexWhere((r) => r.id == room.id);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(room.name),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              _addDevicesToRoom(room);
            },
            child: Text(l10n.roomAddDevices),
          ),
          CupertinoActionSheetAction(
            onPressed: () async {
              Navigator.of(sheetContext).pop();
              final name = await _promptName(
                title: l10n.roomRename,
                initial: room.name,
              );
              if (name == null || name.isEmpty || !mounted) return;
              await ref
                  .read(dashboardLayoutProvider.notifier)
                  .renameRoom(room.id, name);
            },
            child: Text(l10n.roomRename),
          ),
          if (index > 0)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                ref
                    .read(dashboardLayoutProvider.notifier)
                    .reorderRooms(index, index - 1);
              },
              child: Text(l10n.homeMoveRoomUp),
            ),
          if (index >= 0 && index < rooms.length - 1)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                ref
                    .read(dashboardLayoutProvider.notifier)
                    .reorderRooms(index, index + 1);
              },
              child: Text(l10n.homeMoveRoomDown),
            ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () async {
              Navigator.of(sheetContext).pop();
              final confirmed = await showCupertinoDialog<bool>(
                context: context,
                builder: (dialogContext) => CupertinoAlertDialog(
                  title: Text(l10n.roomRemove),
                  content: Text(l10n.homeRemoveRoomMessage),
                  actions: [
                    CupertinoDialogAction(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: Text(l10n.commonCancel),
                    ),
                    CupertinoDialogAction(
                      isDestructiveAction: true,
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: Text(l10n.commonDelete),
                    ),
                  ],
                ),
              );
              if (confirmed == true && mounted) {
                await ref
                    .read(dashboardLayoutProvider.notifier)
                    .removeRoom(room.id);
              }
            },
            child: Text(l10n.roomRemove),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
  }

  Future<void> _pickRoomThenAddDevices() async {
    final layout = ref.read(dashboardLayoutProvider).value;
    final rooms = layout?.rooms ?? const <DashboardRoom>[];
    if (rooms.isEmpty) return;
    if (rooms.length == 1) return _addDevicesToRoom(rooms.first);

    final l10n = AppLocalizations.of(context);
    final chosen = await showCupertinoModalPopup<DashboardRoom>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.roomPickTitle),
        actions: [
          for (final room in rooms)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheetContext, room),
              child: Text(room.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
    if (chosen != null) await _addDevicesToRoom(chosen);
  }

  Future<void> _addDevicesToRoom(DashboardRoom room) async {
    Map<String, HaEntity> allById;
    try {
      allById = await ref.read(entitiesProvider.future);
    } catch (_) {
      allById = const {};
    }
    if (!mounted) return;

    final l10n = AppLocalizations.of(context);
    // Only things worth putting on a wall panel, and nothing the room
    // already holds — there's no useful action for those here.
    final candidates = allById.values
        .where((e) => isHomeEntity(e) && !room.entityIds.contains(e.entityId))
        .toList();

    final picked = await Navigator.of(context).push<List<String>>(
      CupertinoPageRoute(
        builder: (_) => EntityMultiPickerScreen(
          entities: candidates,
          title: l10n.roomAddDevicesTo(room.name),
          emptyMessage: allById.isEmpty ? l10n.entityPickerNotConnected : null,
        ),
      ),
    );

    if (picked == null || picked.isEmpty) return;
    await ref
        .read(dashboardLayoutProvider.notifier)
        .addEntitiesToRoom(room.id, picked);
  }

  /// Seeds rooms from Home Assistant's areas. A convenience, not a link —
  /// once imported the rooms are the user's to edit.
  Future<void> _importHaAreas() async {
    HomeDashboardData data;
    try {
      data = await ref.read(homeDashboardProvider.future);
    } catch (_) {
      if (mounted) {
        await _showMessage(
          AppLocalizations.of(context).dashboardUnreachableMessage,
        );
      }
      return;
    }
    if (!mounted) return;
    if (data.rooms.isEmpty && data.unassigned.isEmpty) {
      await _showMessage(AppLocalizations.of(context).homeImportEmpty);
      return;
    }

    await ref.read(dashboardLayoutProvider.notifier).importRooms({
      if (data.unassigned.isNotEmpty)
        AppLocalizations.of(context).homeOtherRoom: [
          for (final e in data.unassigned) e.entityId,
        ],
      for (final room in data.rooms)
        room.area.name: [for (final e in room.entities) e.entityId],
    });
  }

  Future<void> _showMessage(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(AppLocalizations.of(context).commonOk),
        ),
      ],
    ),
  );

  Future<void> _addWebsite() async {
    final controller = TextEditingController(text: 'https://');
    final url = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(
          AppLocalizations.of(dialogContext).dashboardWebsiteUrlTitle,
        ),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            keyboardType: TextInputType.url,
            autofocus: true,
            placeholder: 'https://example.com',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(AppLocalizations.of(dialogContext).commonCancel),
          ),
          CupertinoDialogAction(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(AppLocalizations.of(dialogContext).commonAdd),
          ),
        ],
      ),
    );

    if (url == null || url.isEmpty || !mounted) return;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      await _showMessage(AppLocalizations.of(context).homeInvalidUrl);
      return;
    }
    await ref
        .read(dashboardLayoutProvider.notifier)
        .addTile(
          TileConfig(
            id: _generateTileId(),
            type: TileType.webview,
            x: 0,
            y: 0,
            width: 3,
            height: 2,
            url: url,
          ),
        );
  }

  Future<void> _addHistoryGraph() async {
    Map<String, HaEntity> allById;
    try {
      allById = await ref.read(entitiesProvider.future);
    } catch (_) {
      allById = const {};
    }
    if (!mounted) return;

    final l10n = AppLocalizations.of(context);
    final chosen = await Navigator.of(context).push<HaEntity>(
      CupertinoPageRoute(
        builder: (_) => EntityPickerScreen(
          entities: allById.values.toList(),
          emptyMessage: allById.isEmpty ? l10n.entityPickerNotConnected : null,
        ),
      ),
    );

    if (chosen == null) return;
    await ref
        .read(dashboardLayoutProvider.notifier)
        .addTile(
          TileConfig(
            id: _generateTileId(),
            type: TileType.history,
            x: 0,
            y: 0,
            width: 3,
            height: 2,
            entityId: chosen.entityId,
          ),
        );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = CupertinoTheme.of(context).primaryColor;
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? accent
              : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
                  context,
                ),
          borderRadius: Radii.brPill,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.lg,
            vertical: Gap.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected
                    ? CupertinoColors.white
                    : CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: AppText.tileTitle.copyWith(
                  color: selected
                      ? CupertinoColors.white
                      : CupertinoColors.label.resolveFrom(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionBanner extends StatefulWidget {
  const _ConnectionBanner({
    required this.status,
    this.entitiesError,
    required this.onRetry,
  });
  final VoidCallback onRetry;

  final HaConnectionStatus? status;

  /// The raw exception from the REST `/api/states` fetch, when it failed.
  /// Surfaced verbatim (not folded into the generic WS-status message)
  /// because the WebSocket and REST paths can succeed/fail independently —
  /// e.g. the WS can report `connected` while the states fetch still 401s.
  final String? entitiesError;

  @override
  State<_ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends State<_ConnectionBanner> {
  bool _dismissed = false;

  @override
  void didUpdateWidget(covariant _ConnectionBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status ||
        oldWidget.entitiesError != widget.entitiesError) {
      _dismissed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final entitiesError = widget.entitiesError;
    final hasWsProblem =
        status != null && status != HaConnectionStatus.connected;
    if (_dismissed || (!hasWsProblem && entitiesError == null)) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final String message;
    if (entitiesError != null) {
      message = entitiesError;
    } else if (status == HaConnectionStatus.connecting) {
      message = l10n.dashboardConnectingMessage;
    } else {
      message = l10n.dashboardUnreachableMessage;
    }

    return Container(
      width: double.infinity,
      color: CupertinoColors.systemOrange,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.wifi_slash,
            size: 16,
            color: CupertinoColors.white,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppText.footnote.copyWith(color: CupertinoColors.white),
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onPressed: widget.onRetry,
            child: Text(
              l10n.commonRetry,
              style: AppText.footnote.copyWith(color: CupertinoColors.white),
            ),
          ),
          // A bare GestureDetector gets exactly its child's hit rect, so
          // this used to be a 16pt target. CupertinoButton enforces the
          // 44pt minimum on its own.
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size.square(IconSizes.minTapTarget),
            onPressed: () => setState(() => _dismissed = true),
            child: const Icon(
              CupertinoIcons.xmark,
              size: IconSizes.caption,
              color: CupertinoColors.white,
            ),
          ),
        ],
      ),
    );
  }
}
