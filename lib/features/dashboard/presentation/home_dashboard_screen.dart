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
import '../domain/home_domains.dart';
import '../domain/tile_config.dart';
import '../providers/dashboard_providers.dart';
import '../providers/home_dashboard_providers.dart';
import 'entity_picker_screen.dart';
import 'tile_kinds.dart';
import 'tiles/home_accessory_tile.dart';
import 'tiles/tile_registry.dart';
import '../../../shared/widgets/section_header.dart';

String _generateTileId() => DateTime.now().microsecondsSinceEpoch.toString();

/// The dashboard, modelled on Apple's Home app: accessories appear
/// automatically, grouped into the rooms Home Assistant already knows
/// about, and the only thing the user curates is which ones are favourites
/// and which are hidden. Nothing is placed or resized by hand.
class HomeDashboardScreen extends ConsumerStatefulWidget {
  const HomeDashboardScreen({super.key});

  @override
  ConsumerState<HomeDashboardScreen> createState() =>
      _HomeDashboardScreenState();
}

class _HomeDashboardScreenState extends ConsumerState<HomeDashboardScreen> {
  /// `null` is the "All" chip.
  HomeCategory? _category;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dataAsync = ref.watch(homeDashboardProvider);
    final connectionStatus = ref.watch(haConnectionStatusProvider);
    final entitiesAsync = ref.watch(entitiesProvider);

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.appTitle),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: _showAddMenu,
                  child: const Icon(CupertinoIcons.add_circled),
                ),
                if (_hasMediaServices())
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => context.push('/media'),
                    child: const Icon(CupertinoIcons.play_rectangle),
                  ),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => context.push('/settings'),
                  child: const Icon(CupertinoIcons.settings),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: _ConnectionBanner(
              status: connectionStatus.value,
              entitiesError: entitiesAsync.hasError
                  ? entitiesAsync.error.toString()
                  : null,
            ),
          ),
          ...dataAsync.when(
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
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  List<Widget> _buildSections(HomeDashboardData data) {
    final l10n = AppLocalizations.of(context);
    final layout = ref.watch(dashboardLayoutProvider).value;
    final enabledServices =
        ref.watch(enabledServicesProvider).value ?? const <AppService>{};
    final widgetTiles = layout?.tiles ?? const <TileConfig>[];

    final favourites = _filtered(data.favorites);
    final unassigned = _filtered(data.unassigned);
    final rooms = [
      for (final room in data.rooms)
        if (_filtered(room.entities).isNotEmpty)
          (room: room, entities: _filtered(room.entities)),
    ];

    // The category strip only makes sense once there is something to
    // filter, and the whole page collapses to an explainer when Home
    // Assistant hasn't given us anything yet.
    if (data.isEmpty && widgetTiles.isEmpty && enabledServices.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: Insets.emptyState,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  CupertinoIcons.house,
                  size: IconSizes.hero,
                  color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                ),
                const SizedBox(height: 16),
                Text(l10n.homeEmptyTitle, style: AppText.emptyStateTitle),
                const SizedBox(height: 8),
                Text(
                  l10n.homeEmptyMessage,
                  textAlign: TextAlign.center,
                  style: AppText.emptyStateBody.copyWith(
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ];
    }

    return [
      SliverToBoxAdapter(child: _summary(data)),
      if (!data.isEmpty) SliverToBoxAdapter(child: _categoryStrip()),
      if (favourites.isNotEmpty) ...[
        _sectionHeader(l10n.homeFavorites),
        _accessoryGrid(favourites),
      ],
      for (final entry in rooms) ...[
        _sectionHeader(entry.room.area.name),
        _accessoryGrid(entry.entities),
      ],
      if (unassigned.isNotEmpty) ...[
        _sectionHeader(l10n.homeOtherRoom),
        _accessoryGrid(unassigned),
      ],
      // Services and hand-added widgets aren't accessories, so the
      // category chips (which describe accessory kinds) don't filter them.
      if (_category == null) ...[
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
        if (widgetTiles.isNotEmpty) ...[
          _sectionHeader(l10n.homeWidgets),
          _tileGrid(widgetTiles, dismissible: true),
        ],
      ],
    ];
  }

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

  Widget _summary(HomeDashboardData data) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.pageGutter,
        0,
        Insets.pageGutter,
        Gap.xs,
      ),
      child: Text(
        data.lightsOn == 0
            ? l10n.homeSummaryAllOff
            : l10n.homeSummaryLightsOn(data.lightsOn),
        style: AppText.subhead.copyWith(
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
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
                  selected: _category == entry.key,
                  onTap: () => setState(() => _category = entry.key),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) => SliverSectionHeader(title: title);

  /// One shared grid geometry for every section, so the whole page reads as
  /// a single uniform layout the way Apple Home's does — two columns on a
  /// phone, more on the tablet, with no per-tile sizing.
  static const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 210,
    mainAxisSpacing: 12,
    crossAxisSpacing: 12,
    childAspectRatio: 1.6,
  );

  Widget _accessoryGrid(List<HaEntity> entities) => SliverPadding(
    padding: Insets.page,
    sliver: SliverGrid(
      gridDelegate: _gridDelegate,
      delegate: SliverChildBuilderDelegate(
        (context, index) => HomeAccessoryTile(entity: entities[index]),
        childCount: entities.length,
      ),
    ),
  );

  Widget _tileGrid(List<TileConfig> tiles, {bool dismissible = false}) =>
      SliverPadding(
        padding: Insets.page,
        sliver: SliverGrid(
          gridDelegate: _gridDelegate,
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

  /// Rooms and services need no adding — the only things a user can put on
  /// this dashboard by hand are the two widget kinds with no Home
  /// Assistant entity behind them.
  Future<void> _showAddMenu() async {
    final l10n = AppLocalizations.of(context);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
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

    if (url == null || url.isEmpty) return;
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
    required this.selected,
    required this.onTap,
  });

  final String label;
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
          child: Text(
            label,
            style: AppText.tileTitle.copyWith(
              color: selected
                  ? CupertinoColors.white
                  : CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionBanner extends StatefulWidget {
  const _ConnectionBanner({required this.status, this.entitiesError});

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
