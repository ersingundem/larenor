import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/icon_sizes.dart';
import '../../../shared/theme/radii.dart';
import '../../../shared/theme/spacing.dart';
import '../../../shared/theme/typography.dart';
import '../../auth/providers/auth_providers.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../health/data/health_configuration.dart';
import '../../keenetic/providers/keenetic_providers.dart';
import '../../ha_client/data/ws_client.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../wellbeing/providers/wellbeing_providers.dart';
import '../../wellbeing/providers/wellbeing_privacy_providers.dart';
import '../../settings/data/app_service.dart';
import '../../settings/providers/enabled_services_providers.dart';
import '../domain/dashboard_card_size.dart';
import '../domain/dashboard_layout.dart';
import '../domain/dashboard_room.dart';
import '../domain/home_domains.dart';
import '../domain/tile_config.dart';
import '../providers/dashboard_providers.dart';
import '../providers/dashboard_live_providers.dart';
import '../providers/home_dashboard_providers.dart';
import 'dashboard_card_editor_screen.dart';
import 'dashboard_card_presentation.dart';
import 'dashboard_edit_guard.dart';
import 'room_area_sync_screen.dart';
import 'widgets/dashboard_grid_delegate.dart';
import 'entity_multi_picker_screen.dart';
import 'dashboard_widget_picker_screen.dart';
import 'tile_kinds.dart';
import 'widgets/home_surface.dart';
import 'tiles/home_accessory_tile.dart';
import 'tiles/tile_registry.dart';
import '../../../shared/widgets/section_header.dart';
import '../../navigation/presentation/app_shell_actions.dart';

/// The dashboard, modelled on Apple's Home app but assembled by hand:
/// rooms the user created, holding devices they picked. Home Assistant
/// supplies live state for those entities; it doesn't decide what appears.
/// Saved ordering and sizes are placed responsively by a lazy grid.
class HomeDashboardScreen extends ConsumerStatefulWidget {
  const HomeDashboardScreen({
    super.key,
    this.embedded = false,
    this.initialRoomId,
  });
  final bool embedded;
  final String? initialRoomId;

  @override
  ConsumerState<HomeDashboardScreen> createState() =>
      _HomeDashboardScreenState();
}

class _HomeDashboardScreenState
    extends DashboardEditState<HomeDashboardScreen> {
  /// `null` is the "All" chip.
  HomeCategory? _category;
  String? _selectedRoom;
  bool _roomMenuBusy = false;
  Route<String>? _roomMenuRoute;
  Route<String>? _addMenuRoute;
  bool _addMenuBusy = false;
  bool _widgetBusy = false;
  final _ownedInteractionRoutes = <Route<dynamic>>{};

  Future<R?> _pushDashboardModal<R>(Route<R> route) async {
    _ownedInteractionRoutes.add(route);
    try {
      return await Navigator.of(context).push<R>(route);
    } finally {
      _ownedInteractionRoutes.remove(route);
    }
  }

  @override
  void invalidateDashboardInteraction() {
    final owned = _ownedInteractionRoutes.toList();
    _ownedInteractionRoutes.clear();
    for (final route in owned) {
      if (route.isActive) route.navigator?.removeRoute(route);
    }
    final addRoute = _addMenuRoute;
    _addMenuRoute = null;
    if (addRoute?.isActive == true) addRoute!.navigator?.removeRoute(addRoute);
    final route = _roomMenuRoute;
    _roomMenuRoute = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  @override
  void initState() {
    super.initState();
    _selectedRoom = widget.initialRoomId;
  }

  @override
  void didUpdateWidget(covariant HomeDashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialRoomId != widget.initialRoomId) {
      _selectedRoom = widget.initialRoomId;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final layoutAsync = ref.watch(dashboardLayoutProvider);
    final connectionStatus = ref.watch(haConnectionStatusProvider);
    final entitiesError = ref.watch(
      entitiesProvider.select((states) => states.hasError),
    );

    final layout = layoutAsync.value;
    final rooms = layout?.rooms ?? const <DashboardRoom>[];
    if (rooms.any((room) => room.areaBinding != null)) {
      ref.watch(connectionConfigProvider);
    }
    watchDashboardAccount();
    final selectedRoom = rooms.where((r) => r.id == _selectedRoom).firstOrNull;
    final wide = !widget.embedded && MediaQuery.sizeOf(context).width >= 1000;
    final hasMedia = _hasMediaServices();

    final content = CustomScrollView(
      key: PageStorageKey('home-${widget.initialRoomId ?? 'overview'}'),
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
              if (widget.embedded) const AppShellActions(),
              if (!widget.embedded && !wide && hasMedia)
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => context.push('/media'),
                  child: Semantics(
                    label: l10n.homeCategoryMedia,
                    child: const Icon(CupertinoIcons.play_rectangle),
                  ),
                ),
              if (!widget.embedded && !wide)
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
            entitiesError: entitiesError,
            onRetry: _refresh,
          ),
        ),
        if (widget.embedded && _selectedRoom == null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Wrap(
                children: [
                  CupertinoButton(
                    onPressed: () => context.go('/today'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(CupertinoIcons.calendar, size: 20),
                        const SizedBox(width: 8),
                        Flexible(child: Text(l10n.todayTitle)),
                      ],
                    ),
                  ),
                  CupertinoButton(
                    onPressed: () => context.go('/intercom'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(CupertinoIcons.bell, size: 20),
                        const SizedBox(width: 8),
                        Flexible(child: Text(l10n.intercomTitle)),
                      ],
                    ),
                  ),
                  CupertinoButton(
                    onPressed: () => context.go('/energy'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(CupertinoIcons.bolt_fill, size: 20),
                        const SizedBox(width: 8),
                        Flexible(child: Text(l10n.energyTitle)),
                      ],
                    ),
                  ),
                ],
              ),
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
                    l10n.dashboardEditFailed,
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

  void _selectRoom(String? id) {
    if (widget.embedded) {
      context.go(
        id == null ? '/' : Uri(pathSegments: ['', 'rooms', id]).toString(),
      );
    } else {
      setState(() => _selectedRoom = id);
    }
  }

  /// The dashboard is what the user assembled: rooms they made, holding
  /// devices they picked. Home Assistant supplies live state for those
  /// entities and nothing else — it no longer decides what's on screen.
  List<Widget> _buildSections(DashboardLayout layout) {
    final l10n = AppLocalizations.of(context);
    final categories = ref.watch(dashboardCategoriesProvider).byId;
    final enabledServices =
        ref.watch(enabledServicesProvider).value ?? const <AppService>{};

    List<String> resolve(Iterable<String> ids) => [
      for (final id in ids.toSet())
        if (categories.containsKey(id) &&
            (_category == null || categories[id] == _category))
          id,
    ];
    final selectedRoom = layout.rooms
        .where((r) => r.id == _selectedRoom)
        .firstOrNull;

    final favourites = resolve(layout.favoriteEntityIds);
    final rooms = [
      for (final room in layout.rooms)
        if (selectedRoom == null || room.id == selectedRoom.id)
          (
            room: room,
            entities: resolve(room.entityIds),
            compatible: roomMatchesCurrentServer(ref, room),
          ),
    ];

    if (layout.rooms.isEmpty &&
        layout.tiles.isEmpty &&
        enabledServices.isEmpty &&
        favourites.isEmpty) {
      return [_emptyState(l10n)];
    }

    return [
      const SliverToBoxAdapter(child: HomeOverview()),
      if (layout.rooms.isNotEmpty &&
          (widget.embedded || MediaQuery.sizeOf(context).width < 1000))
        SliverToBoxAdapter(child: _roomStrip(layout.rooms, selectedRoom?.id)),
      if (rooms.isNotEmpty || favourites.isNotEmpty)
        SliverToBoxAdapter(child: _categoryStrip()),
      if (favourites.isNotEmpty && selectedRoom == null) ...[
        _sectionHeader(l10n.homeFavorites),
        _accessoryGrid(favourites, sizes: layout.entityCardSizes),
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
        if (_category == null ||
            entry.entities.isNotEmpty ||
            !entry.compatible) ...[
          _sectionHeader(entry.room.name, room: entry.room),
          if (!entry.compatible)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.roomSyncMismatch),
                    CupertinoButton(
                      onPressed: dashboardAction(
                        () => _openRoomSync(entry.room),
                      ),
                      child: Text(l10n.roomSyncArea),
                    ),
                  ],
                ),
              ),
            )
          else if (entry.entities.isEmpty)
            SliverToBoxAdapter(child: _roomPlaceholder(l10n, entry.room))
          else
            _accessoryGrid(
              entry.entities,
              room: entry.room,
              sizes: layout.entityCardSizes,
            ),
        ],
      // Services and hand-added widgets aren't accessories, so the
      // category chips (which describe accessory kinds) don't filter them.
      if (_category == null && selectedRoom == null) ...[
        if (enabledServices.isNotEmpty) ...[
          _sectionHeader(
            l10n.homeServices,
            onEdit: () => _openEditor(
              DashboardEditorMode.services,
              services: enabledServices.toList(),
            ),
          ),
          _tileGrid([
            for (final service in AppService.values)
              if (enabledServices.contains(service))
                TileConfig(
                  id: 'service-${service.name}',
                  type: serviceTileTypes[service]!,
                  x: 0,
                  y: 0,
                  width: cardSizeSpan(
                    layout.serviceCardSizes[service.name] ??
                        DashboardCardSize.medium,
                  ).columns,
                  height: cardSizeSpan(
                    layout.serviceCardSizes[service.name] ??
                        DashboardCardSize.medium,
                  ).rows,
                ),
          ]),
        ],
        if (layout.tiles.isNotEmpty) ...[
          _sectionHeader(
            l10n.homeWidgets,
            onEdit: () => _openEditor(DashboardEditorMode.widgets),
          ),
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
                onPressed: () => _selectRoom(entry.key),
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

  Widget _sectionHeader(
    String title, {
    DashboardRoom? room,
    VoidCallback? onEdit,
  }) => SliverSectionHeader(
    title: title,
    trailing: room == null && onEdit == null
        ? null
        : CupertinoButton(
            key: room == null ? null : ValueKey('home-room-menu-${room.id}'),
            padding: EdgeInsets.zero,
            minimumSize: const Size.square(48),
            onPressed: dashboardAction(onEdit ?? () => _showRoomMenu(room!)),
            child: Icon(
              CupertinoIcons.ellipsis_circle,
              size: IconSizes.body,
              semanticLabel: room == null
                  ? AppLocalizations.of(context)
                        .dashboardEditSectionLabel(title)
                  : AppLocalizations.of(context)
                        .dashboardRoomMenuLabel(room.name),
            ),
          ),
  );

  SliverGridDelegate _gridDelegate(
    List<DashboardGridSpan> spans, {
    bool service = false,
  }) => DashboardGridDelegate(
    spans: spans,
    rowExtent: service
        ? dashboardServiceRowExtent(context)
        : HomeAccessoryTile.heightFor(context),
  );

  Widget _accessoryGrid(
    List<String> entityIds, {
    DashboardRoom? room,
    Map<String, DashboardCardSize> sizes = const {},
  }) => SliverPadding(
    padding: Insets.page,
    sliver: SliverGrid(
      gridDelegate: _gridDelegate([
        for (final id in entityIds)
          cardSizeSpan(sizes[id] ?? DashboardCardSize.small),
      ]),
      delegate: SliverChildBuilderDelegate(
        (context, index) => LiveHomeAccessoryTile(
          key: ValueKey(entityIds[index]),
          entityId: entityIds[index],
          roomId: room?.id,
        ),
        childCount: entityIds.length,
      ),
    ),
  );

  Widget _tileGrid(List<TileConfig> tiles, {bool dismissible = false}) {
    final privacy = ref.watch(wellbeingPrivateEntityIdsProvider);
    final visibleTiles = tiles
        .where(
          (tile) =>
              tile.entityId == null || isPublicHaEntity(privacy, tile.entityId),
        )
        .toList();
    if (visibleTiles.isEmpty) return const SliverToBoxAdapter();
    return SliverPadding(
      padding: Insets.page,
      sliver: SliverGrid(
        gridDelegate: _gridDelegate([
          for (final tile in visibleTiles)
            DashboardGridSpan(tile.width.clamp(1, 6), tile.height.clamp(1, 4)),
        ], service: true),
        delegate: SliverChildBuilderDelegate((context, index) {
          final tile = visibleTiles[index];
          final content = ClipRRect(
            borderRadius: Radii.brLarge,
            child: buildTileContent(tile),
          );
          if (!dismissible) return content;
          return GestureDetector(
            onLongPress: dashboardAction(() => _confirmRemoveWidget(tile)),
            child: content,
          );
        }, childCount: visibleTiles.length),
      ),
    );
  }

  void _openEditor(
    DashboardEditorMode mode, {
    DashboardRoom? room,
    List<AppService> services = const [],
  }) {
    if (!mounted) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => DashboardCardEditorScreen(
          mode: mode,
          roomId: room?.id,
          services: services,
        ),
      ),
    );
  }

  void _openRoomSync(DashboardRoom room) {
    if (!mounted) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => RoomAreaSyncScreen(roomId: room.id),
      ),
    );
  }

  Future<void> _confirmRemoveWidget(TileConfig tile) async {
    final generation = interactionGeneration;
    if (!interactionCurrent(generation)) return;
    final l10n = AppLocalizations.of(context);
    final action = await _pushDashboardModal(
      CupertinoModalPopupRoute<String>(
        builder: (sheetContext) => CupertinoActionSheet(
          title: Text(tile.title ?? tile.url ?? l10n.homeWidgets),
          actions: [
            CupertinoActionSheetAction(
              onPressed: () => closeDashboardModal(sheetContext, 'edit'),
              child: Text(l10n.dashboardCardSize),
            ),
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => closeDashboardModal(sheetContext, 'remove'),
              child: Text(l10n.commonRemove),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => closeDashboardModal(sheetContext),
            child: Text(l10n.commonCancel),
          ),
        ),
      ),
    );
    if (!interactionCurrent(generation)) return;
    if (action == 'edit') _openEditor(DashboardEditorMode.widgets);
    if (action == 'remove') {
      await ref.read(dashboardLayoutProvider.notifier).removeTile(tile.id);
    }
  }

  Future<void> _showAddMenu() async {
    final generation = interactionGeneration;
    if (!interactionCurrent(generation) || _addMenuBusy || _widgetBusy) return;
    final l10n = AppLocalizations.of(context);
    final hasRooms =
        ref.read(dashboardLayoutProvider).value?.rooms.isNotEmpty ?? false;
    _addMenuBusy = true;
    final route = CupertinoModalPopupRoute<String>(
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
          for (final (value, label) in [
            ('widget', l10n.widgetGalleryTitle),
            ('room', l10n.dashboardAddRoom),
            if (hasRooms) ('devices', l10n.roomAddDevices),
            ('areas', l10n.roomImportAreas),
            ('website', l10n.homeAddWebsite),
            ('history', l10n.homeAddHistory),
          ])
            CupertinoActionSheetAction(
              onPressed: () => closeDashboardModal(sheetContext, value),
              child: Text(label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => closeDashboardModal(sheetContext),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
    _addMenuRoute = route;
    try {
      final action = await Navigator.of(context).push<String>(route);
      if (identical(_addMenuRoute, route)) _addMenuRoute = null;
      if (!interactionCurrent(generation)) return;
      switch (action) {
        case 'widget':
          await _addWidget();
        case 'room':
          await _promptAddRoom();
        case 'devices':
          await _pickRoomThenAddDevices();
        case 'areas':
          await _importHaAreas();
        case 'website':
          await _addWidget(initialType: TileType.webview);
        case 'history':
          await _addWidget(initialType: TileType.history);
      }
    } catch (_) {
      if (interactionCurrent(generation)) {
        await _showMessage(l10n.dashboardEditFailed);
      }
    } finally {
      _addMenuBusy = false;
    }
  }

  Future<void> _addWidget({TileType? initialType}) async {
    if (!interactionCurrent(interactionGeneration) || _widgetBusy) return;
    _widgetBusy = true;
    final failureMessage = AppLocalizations.of(context).dashboardEditFailed;
    final generation = interactionGeneration;
    void Function()? closeAccount;
    var accountValid = true;
    try {
      final tile = await pushDashboardPage<TileConfig>(
        CupertinoPageRoute(
          builder: (_) => DashboardWidgetPickerScreen(initialType: initialType),
        ),
      );
      if (tile == null || !interactionCurrent(generation)) return;
      // The picker validates its source before returning. Keep that identity
      // guarded while the local save waits behind another configuration write.
      bool Function() accountCurrent = () => true;
      if (tile.type == TileType.keenetic) {
        final source = ref.read(keeneticConnectionProvider);
        if (source.isLoading || source.hasError) return;
        accountCurrent = () {
          final next = ref.read(keeneticConnectionProvider);
          return !next.isLoading &&
              !next.hasError &&
              sameHealthConfiguration(source.value, next.value);
        };
        final subscription = ref.listenManual(keeneticConnectionProvider, (
          _,
          next,
        ) {
          if (next.isLoading ||
              next.hasError ||
              !sameHealthConfiguration(source.value, next.value)) {
            accountValid = false;
          }
        });
        closeAccount = subscription.close;
      } else if (tile.entityId != null) {
        final source = ref.read(connectionConfigProvider);
        if (source.isLoading || source.hasError || source.value == null) return;
        accountCurrent = () {
          final next = ref.read(connectionConfigProvider);
          return !next.isLoading &&
              !next.hasError &&
              sameHealthConfiguration(source.value, next.value);
        };
        final subscription = ref.listenManual(connectionConfigProvider, (
          _,
          next,
        ) {
          if (next.isLoading ||
              next.hasError ||
              !sameHealthConfiguration(source.value, next.value)) {
            accountValid = false;
          }
        });
        closeAccount = subscription.close;
      }
      bool current() =>
          interactionCurrent(generation) && accountValid && accountCurrent();
      await ref
          .read(dashboardLayoutProvider.notifier)
          .addTile(tile, isCurrent: current);
    } catch (_) {
      if (interactionCurrent(generation)) {
        await _showMessage(failureMessage);
      }
    } finally {
      closeAccount?.call();
      _widgetBusy = false;
    }
  }

  Future<String?> _promptName({
    required String title,
    String? initial,
    String? placeholder,
    String? confirmLabel,
    TextInputType? keyboardType,
  }) {
    final l10n = AppLocalizations.of(context);
    return _pushDashboardModal(
      CupertinoDialogRoute<String>(
        context: context,
        builder: (_) => _DashboardTextDialog(
          title: title,
          initial: initial,
          placeholder: placeholder ?? l10n.roomNamePlaceholder,
          confirmLabel: confirmLabel ?? l10n.commonSave,
          cancelLabel: l10n.commonCancel,
          keyboardType: keyboardType,
        ),
      ),
    );
  }

  Future<void> _promptAddRoom() async {
    final generation = interactionGeneration;
    if (!interactionCurrent(generation)) return;
    final name = await _promptName(
      title: AppLocalizations.of(context).roomAddTitle,
    );
    if (name == null || name.isEmpty || !interactionCurrent(generation)) return;
    await ref.read(dashboardLayoutProvider.notifier).addRoom(name);
  }

  Future<void> _showRoomMenu(DashboardRoom room) async {
    final generation = interactionGeneration;
    if (_roomMenuBusy || !interactionCurrent(generation)) return;
    _roomMenuBusy = true;
    final l10n = AppLocalizations.of(context);
    final rooms =
        ref.read(dashboardLayoutProvider).value?.rooms ??
        const <DashboardRoom>[];
    final index = rooms.indexWhere((r) => r.id == room.id);
    final compatible = roomMatchesCurrentServer(ref, room);
    final choices = <String, String>{
      'edit': l10n.dashboardEditRoom,
      'sync': room.areaBinding == null ? l10n.roomBindArea : l10n.roomSyncArea,
      if (compatible) 'add': l10n.roomAddDevices,
      'rename': l10n.roomRename,
      if (index > 0) 'up': l10n.homeMoveRoomUp,
      if (index >= 0 && index < rooms.length - 1) 'down': l10n.homeMoveRoomDown,
      'remove': l10n.roomRemove,
    };
    final route = CupertinoModalPopupRoute<String>(
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(room.name),
        actions: [
          for (final entry in choices.entries)
            CupertinoActionSheetAction(
              key: ValueKey('room-menu-${entry.key}'),
              isDestructiveAction: entry.key == 'remove',
              onPressed: () {
                if (sheetContext.mounted &&
                    ModalRoute.of(sheetContext)?.isCurrent == true) {
                  closeDashboardModal(sheetContext, entry.key);
                }
              },
              child: Text(entry.value),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => closeDashboardModal(sheetContext),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
    _roomMenuRoute = route;
    try {
      final action = await Navigator.of(context).push<String>(route);
      if (identical(_roomMenuRoute, route)) _roomMenuRoute = null;
      if (!mounted || !interactionCurrent(generation) || action == null) return;
      final notifier = ref.read(dashboardLayoutProvider.notifier);
      final currentRooms =
          ref.read(dashboardLayoutProvider).value?.rooms ??
          const <DashboardRoom>[];
      final currentIndex = currentRooms.indexWhere(
        (item) => item.id == room.id,
      );
      switch (action) {
        case 'edit':
          _openEditor(DashboardEditorMode.room, room: room);
        case 'sync':
          _openRoomSync(room);
        case 'add':
          await _addDevicesToRoom(room);
        case 'rename':
          final name = await _promptName(
            title: l10n.roomRename,
            initial: room.name,
          );
          if (!mounted ||
              !interactionCurrent(generation) ||
              name == null ||
              name.isEmpty) {
            return;
          }
          await notifier.renameRoom(room.id, name);
        case 'up':
          if (currentIndex > 0) {
            await notifier.reorderRooms(currentIndex, currentIndex - 1);
          }
        case 'down':
          if (currentIndex >= 0 && currentIndex < currentRooms.length - 1) {
            await notifier.reorderRooms(currentIndex, currentIndex + 1);
          }
        case 'remove':
          final confirmed = await _pushDashboardModal(
            CupertinoDialogRoute<bool>(
              context: context,
              builder: (dialogContext) => CupertinoAlertDialog(
                title: Text(l10n.roomRemove),
                content: Text(l10n.homeRemoveRoomMessage),
                actions: [
                  CupertinoDialogAction(
                    onPressed: () => closeDashboardModal(dialogContext, false),
                    child: Text(l10n.commonCancel),
                  ),
                  CupertinoDialogAction(
                    isDestructiveAction: true,
                    onPressed: () => closeDashboardModal(dialogContext, true),
                    child: Text(l10n.commonDelete),
                  ),
                ],
              ),
            ),
          );
          if (confirmed == true && interactionCurrent(generation)) {
            await notifier.removeRoom(room.id);
          }
      }
    } catch (_) {
      if (mounted && interactionCurrent(generation)) {
        await _showMessage(l10n.dashboardEditFailed);
      }
    } finally {
      _roomMenuBusy = false;
    }
  }

  Future<void> _pickRoomThenAddDevices() async {
    final generation = interactionGeneration;
    if (!interactionCurrent(generation)) return;
    final layout = ref.read(dashboardLayoutProvider).value;
    final rooms = layout?.rooms ?? const <DashboardRoom>[];
    if (rooms.isEmpty) return;
    if (rooms.length == 1) return _addDevicesToRoom(rooms.first);

    final l10n = AppLocalizations.of(context);
    final chosen = await _pushDashboardModal(
      CupertinoModalPopupRoute<DashboardRoom>(
        builder: (sheetContext) => CupertinoActionSheet(
          title: Text(l10n.roomPickTitle),
          actions: [
            for (final room in rooms)
              CupertinoActionSheetAction(
                onPressed: () => closeDashboardModal(sheetContext, room),
                child: Text(room.name),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => closeDashboardModal(sheetContext),
            child: Text(l10n.commonCancel),
          ),
        ),
      ),
    );
    if (chosen != null && interactionCurrent(generation)) {
      await _addDevicesToRoom(chosen);
    }
  }

  Future<void> _addDevicesToRoom(DashboardRoom room) async {
    final generation = interactionGeneration;
    if (!mounted ||
        !interactionCurrent(generation) ||
        !roomMatchesCurrentServer(ref, room)) {
      return;
    }
    Map<String, HaEntity> allById;
    try {
      allById = await ref.read(entitiesProvider.future);
    } catch (_) {
      allById = const {};
    }
    if (!mounted ||
        !interactionCurrent(generation) ||
        !roomMatchesCurrentServer(ref, room)) {
      return;
    }

    final l10n = AppLocalizations.of(context);
    // Only things worth putting on a wall panel, and nothing the room
    // already holds — there's no useful action for those here.
    final existing = room.entityIds.toSet();
    final privacy = ref.read(wellbeingPrivateEntityIdsProvider);
    final candidates = allById.values
        .where(
          (e) =>
              isHomeEntity(e) &&
              !existing.contains(e.entityId) &&
              isPublicHaEntity(privacy, e.entityId),
        )
        .toList();

    final picked = await pushDashboardPage<List<String>>(
      CupertinoPageRoute(
        builder: (_) => Consumer(
          builder: (_, pickerRef, _) {
            final currentPrivacy = pickerRef.watch(
              wellbeingPrivateEntityIdsProvider,
            );
            return EntityMultiPickerScreen(
              entities: candidates
                  .where(
                    (entity) =>
                        isPublicHaEntity(currentPrivacy, entity.entityId),
                  )
                  .toList(),
              title: l10n.roomAddDevicesTo(room.name),
              emptyMessage: allById.isEmpty
                  ? l10n.entityPickerNotConnected
                  : null,
            );
          },
        ),
      ),
    );

    if (picked == null ||
        picked.isEmpty ||
        !interactionCurrent(generation) ||
        !roomMatchesCurrentServer(ref, room)) {
      return;
    }
    final currentPrivacy = ref.read(wellbeingPrivateEntityIdsProvider);
    final publicPicked = picked
        .where((id) => isPublicHaEntity(currentPrivacy, id))
        .toList();
    if (publicPicked.isEmpty) return;
    await ref
        .read(dashboardLayoutProvider.notifier)
        .addEntitiesToRoom(room.id, publicPicked);
  }

  /// Seeds rooms from Home Assistant's areas. A convenience, not a link —
  /// once imported the rooms are the user's to edit.
  Future<void> _importHaAreas() async {
    final generation = interactionGeneration;
    if (!interactionCurrent(generation)) return;
    final l10n = AppLocalizations.of(context);
    HomeDashboardData data;
    try {
      data = await ref.read(homeDashboardProvider.future);
    } catch (_) {
      if (interactionCurrent(generation)) {
        await _showMessage(l10n.dashboardUnreachableMessage);
      }
      return;
    }
    if (!interactionCurrent(generation)) return;
    if (data.rooms.isEmpty && data.unassigned.isEmpty) {
      await _showMessage(l10n.homeImportEmpty);
      return;
    }

    await ref.read(dashboardLayoutProvider.notifier).importRooms({
      if (data.unassigned.isNotEmpty)
        l10n.homeOtherRoom: [for (final e in data.unassigned) e.entityId],
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
          onPressed: () => closeDashboardModal(dialogContext),
          child: Text(AppLocalizations.of(context).commonOk),
        ),
      ],
    ),
  );
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
    this.entitiesError = false,
    required this.onRetry,
  });
  final VoidCallback onRetry;

  final HaConnectionStatus? status;

  /// REST read failure is separate from WebSocket status, without raw errors.
  final bool entitiesError;

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
    if (_dismissed || (!hasWsProblem && !entitiesError)) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final String message;
    if (entitiesError) {
      message = l10n.healthReadError;
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

/// The dialog owns its editor until its route has finished animating out.
class _DashboardTextDialog extends StatefulWidget {
  const _DashboardTextDialog({
    required this.title,
    required this.placeholder,
    required this.confirmLabel,
    required this.cancelLabel,
    this.initial,
    this.keyboardType,
  });

  final String title;
  final String placeholder;
  final String confirmLabel;
  final String cancelLabel;
  final String? initial;
  final TextInputType? keyboardType;

  @override
  State<_DashboardTextDialog> createState() => _DashboardTextDialogState();
}

class _DashboardTextDialogState extends State<_DashboardTextDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoAlertDialog(
    title: Text(widget.title),
    content: Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: CupertinoTextField(
        controller: _controller,
        keyboardType: widget.keyboardType,
        autofocus: true,
        placeholder: widget.placeholder,
      ),
    ),
    actions: [
      CupertinoDialogAction(
        onPressed: () => closeDashboardModal(context),
        child: Text(widget.cancelLabel),
      ),
      CupertinoDialogAction(
        onPressed: () => closeDashboardModal(context, _controller.text.trim()),
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}
