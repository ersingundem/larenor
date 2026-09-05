import '../domain/dashboard_website_url.dart';
export '../domain/dashboard_website_url.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../admin/data/models/ha_registry_entry.dart';
import '../../admin/providers/admin_providers.dart';
import '../../auth/providers/auth_providers.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../health/data/health_configuration.dart';
import '../../wellbeing/providers/wellbeing_privacy_providers.dart';
import '../../keenetic/presentation/keenetic_widget_picker_screen.dart';
import '../../keenetic/providers/keenetic_providers.dart';
import '../domain/tile_config.dart';
import 'dashboard_edit_guard.dart';
import 'tile_kinds.dart';

/// Optional registry metadata. A denied read is shown explicitly and never
/// automatically retried; current state entries remain usable without admin.
final dashboardWidgetRegistryProvider =
    FutureProvider.autoDispose<List<HaRegistryEntry>>((ref) async {
      final connection = ref.watch(connectionConfigProvider);
      if (connection.isLoading ||
          connection.hasError ||
          connection.value == null) {
        throw StateError('connection_unavailable');
      }
      final client = ref.watch(haAdminClientProvider);
      if (client == null) throw StateError('connection_unavailable');
      return client.listEntityRegistry().timeout(const Duration(seconds: 15));
    }, retry: (_, _) => null);

/// HistoryTile plots numeric state readings, not on/off timelines. A device
/// with explicit numeric metadata can still be chosen while unavailable.
bool dashboardWidgetSupports(TileType type, HaEntity entity) {
  if (type == TileType.entity) return true;
  if (type == TileType.history) {
    if (const {
      'date',
      'timestamp',
    }.contains(entity.attributes['device_class'])) {
      return false;
    }
    final number = double.tryParse(entity.state);
    if (number?.isFinite == true) return true;
    if (!const {
      'sensor',
      'number',
      'input_number',
      'counter',
    }.contains(entity.domain)) {
      return false;
    }
    final unit = entity.attributes['unit_of_measurement'];
    return (unit is String && unit.isNotEmpty) ||
        const {
          'measurement',
          'total',
          'total_increasing',
        }.contains(entity.attributes['state_class']) ||
        const {'number', 'input_number', 'counter'}.contains(entity.domain);
  }
  return tileKinds[type]?.domainFilter == entity.domain;
}

String _entityName(HaEntity entity) {
  final name = entity.attributes['friendly_name'];
  return name is String && name.isNotEmpty ? name : entity.entityId;
}

/// Produces a local TileConfig draft only. Live tile widgets deliberately
/// never appear here: selecting a kind cannot start playback or actuate a HA
/// device. The caller owns durable storage and its queued-write guard.
class DashboardWidgetPickerScreen extends ConsumerStatefulWidget {
  const DashboardWidgetPickerScreen({super.key, this.initialType});
  final TileType? initialType;

  @override
  ConsumerState<DashboardWidgetPickerScreen> createState() =>
      _DashboardWidgetPickerScreenState();
}

class _DashboardWidgetPickerScreenState
    extends DashboardEditState<DashboardWidgetPickerScreen> {
  TileType? _type;
  String _query = '';
  bool _expired = false;
  bool _accountSeen = false;
  bool _returned = false;
  bool _openingKeenetic = false;
  final _website = TextEditingController(text: 'https://');
  bool _invalidWebsite = false;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
  }

  @override
  void invalidateDashboardInteraction() {
    // Initial asynchronous loading of an account is not a session switch.
    if (!foreground || _accountSeen) _expired = true;
    _website.clear();
  }

  @override
  void dispose() {
    _website.dispose();
    super.dispose();
  }

  bool get _current => foreground && !_expired && !_returned;

  void _chooseType(TileType type) {
    if (!_current || _openingKeenetic) return;
    setState(() {
      _type = type;
      _query = '';
      _invalidWebsite = false;
    });
  }

  void _complete(TileConfig tile) {
    if (!_current || ModalRoute.of(context)?.isCurrent != true) return;
    _returned = true;
    Navigator.pop(context, tile);
  }

  TileConfig _draft(TileType type, {String? entityId, String? url}) =>
      TileConfig(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        type: type,
        x: 0,
        y: 0,
        width: type == TileType.entity ? 1 : 2,
        height: type == TileType.entity ? 1 : 2,
        entityId: entityId,
        url: url,
      );

  Future<void> _keenetic() async {
    if (!_current || _openingKeenetic) return;
    final generation = interactionGeneration;
    setState(() => _openingKeenetic = true);
    try {
      final tile = await pushDashboardPage<TileConfig>(
        CupertinoPageRoute(builder: (_) => const KeeneticWidgetPickerScreen()),
      );
      if (tile != null && interactionCurrent(generation)) _complete(tile);
    } finally {
      if (mounted) setState(() => _openingKeenetic = false);
    }
  }

  void _selectEntity(HaEntity selected, int generation) {
    if (!interactionCurrent(generation) || !_current || _type == null) return;
    final config = ref.read(connectionConfigProvider);
    final states = ref.read(publicHaEntitiesProvider);
    final registry = ref.read(dashboardWidgetRegistryProvider);
    if (config.isLoading ||
        config.hasError ||
        config.value == null ||
        states.isLoading ||
        states.hasError ||
        registry.isLoading) {
      return;
    }
    final latest = states.value?[selected.entityId];
    final entry = registry.hasError
        ? null
        : registry.value
              ?.where((entry) => entry.entityId == selected.entityId)
              .firstOrNull;
    if (latest == null ||
        !dashboardWidgetSupports(_type!, latest) ||
        entry?.disabledBy != null ||
        entry?.hiddenBy != null) {
      return;
    }
    _complete(_draft(_type!, entityId: latest.entityId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final haType = _type != null && tileKinds.containsKey(_type);
    final config = haType ? ref.watch(connectionConfigProvider) : null;
    watchDashboardAccount();
    if (ref.exists(keeneticConnectionProvider)) {
      ref.watch(keeneticConnectionProvider);
      ref.listen(keeneticConnectionProvider, (previous, next) {
        if (_openingKeenetic &&
            (next.isLoading ||
                next.hasError ||
                !sameHealthConfiguration(previous?.value, next.value))) {
          setState(() {
            interactionGeneration++;
            _expired = true;
          });
        }
      });
    }
    if (config != null && !config.isLoading && !config.hasError) {
      _accountSeen = true;
    } else if (ref.exists(connectionConfigProvider)) {
      final saved = ref.read(connectionConfigProvider);
      if (!saved.isLoading && !saved.hasError) _accountSeen = true;
    }
    final generation = interactionGeneration;
    final slivers = <Widget>[];
    if (!_current) {
      slivers.add(
        SliverToBoxAdapter(child: _message(l10n.dashboardWidgetPickerExpired)),
      );
    } else if (_type == null) {
      slivers.add(
        SliverToBoxAdapter(child: _message(l10n.dashboardWidgetPickerHint)),
      );
      final types = [...tileKinds.keys, TileType.webview, TileType.keenetic];
      slivers.add(
        SliverList.builder(
          itemCount: types.length,
          itemBuilder: (context, index) {
            final type = types[index];
            final kind =
                tileKinds[type] ?? serviceTileKinds[type] ?? webviewTileKind;
            return _choice(
              key: ValueKey('widget-kind-${type.name}'),
              title: tileTypeLabel(context, type),
              icon: kind.icon,
              onPressed: _openingKeenetic
                  ? null
                  : dashboardAction(() {
                      if (type == TileType.keenetic) {
                        _keenetic();
                      } else {
                        _chooseType(type);
                      }
                    }),
            );
          },
        ),
      );
    } else if (_type == TileType.webview) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.dashboardWidgetPickerWebsiteHint),
                const SizedBox(height: 20),
                CupertinoTextField(
                  key: const ValueKey('widget-website-url'),
                  controller: _website,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  placeholder: 'https://example.com',
                  onChanged: (_) {
                    if (_invalidWebsite) {
                      setState(() => _invalidWebsite = false);
                    }
                  },
                ),
                if (_invalidWebsite)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(l10n.homeInvalidUrl),
                  ),
                const SizedBox(height: 16),
                CupertinoButton.filled(
                  key: const ValueKey('widget-website-add'),
                  onPressed: dashboardAction(() {
                    final url = dashboardWebsiteUrl(_website.text);
                    if (url == null) {
                      setState(() => _invalidWebsite = true);
                      return;
                    }
                    _complete(_draft(TileType.webview, url: url));
                  }),
                  child: Text(l10n.commonAdd),
                ),
              ],
            ),
          ),
        ),
      );
    } else if (config?.isLoading == true) {
      slivers.add(
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: CupertinoActivityIndicator(),
          ),
        ),
      );
    } else if (config?.hasError == true) {
      slivers.add(
        SliverToBoxAdapter(
          child: _message(l10n.dashboardWidgetPickerUnavailable),
        ),
      );
    } else if (config?.value == null) {
      slivers.add(
        SliverToBoxAdapter(child: _message(l10n.entityPickerNotConnected)),
      );
    } else {
      final states = ref.watch(publicHaEntitiesProvider);
      final registry = ref.watch(dashboardWidgetRegistryProvider);
      slivers.add(
        SliverToBoxAdapter(
          child: _message(
            _type == TileType.history
                ? l10n.dashboardWidgetPickerHistoryHint
                : l10n.dashboardWidgetPickerReadOnly,
          ),
        ),
      );
      if (states.isLoading || registry.isLoading) {
        slivers.add(
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: CupertinoActivityIndicator(),
            ),
          ),
        );
      } else if (states.hasError) {
        slivers.add(
          SliverToBoxAdapter(
            child: Column(
              children: [
                _message(l10n.dashboardWidgetPickerUnavailable),
                CupertinoButton(
                  onPressed: dashboardAction(
                    () => ref.invalidate(entitiesProvider),
                  ),
                  child: Text(l10n.commonRetry),
                ),
              ],
            ),
          ),
        );
      } else {
        if (registry.hasError) {
          slivers.add(
            SliverToBoxAdapter(
              child: _message(l10n.dashboardWidgetPickerRegistryPartial),
            ),
          );
        }
        final blocked = <String>{
          if (!registry.hasError)
            for (final entry in registry.value ?? const <HaRegistryEntry>[])
              if (entry.disabledBy != null || entry.hiddenBy != null)
                entry.entityId,
        };
        final compatible =
            (states.value?.values ?? const <HaEntity>[])
                .where(
                  (entity) =>
                      !blocked.contains(entity.entityId) &&
                      dashboardWidgetSupports(_type!, entity),
                )
                .toList()
              ..sort((a, b) => _entityName(a).compareTo(_entityName(b)));
        final query = _query.toLowerCase();
        final visible = compatible
            .where(
              (entity) =>
                  _entityName(entity).toLowerCase().contains(query) ||
                  entity.entityId.toLowerCase().contains(query),
            )
            .toList();
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: CupertinoSearchTextField(
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
          ),
        );
        if (visible.isEmpty) {
          slivers.add(
            SliverToBoxAdapter(
              child: _message(
                compatible.isEmpty
                    ? l10n.dashboardWidgetPickerNoCompatible
                    : l10n.dashboardWidgetPickerSearchEmpty,
              ),
            ),
          );
        }
        slivers.add(
          SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final entity = visible[index];
              return _choice(
                key: ValueKey('widget-entity-${entity.entityId}'),
                title: _entityName(entity),
                subtitle: entity.entityId,
                icon: tileKinds[_type]!.icon,
                onPressed: () => _selectEntity(entity, generation),
              );
            },
          ),
        );
      }
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        leading: _type != null && widget.initialType == null && _current
            ? CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: dashboardAction(
                  () => setState(() {
                    _type = null;
                    _query = '';
                  }),
                ),
                child: Text(l10n.commonBack),
              )
            : null,
        middle: Text(
          _type == null
              ? l10n.widgetGalleryTitle
              : tileTypeLabel(context, _type!),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => closeDashboardModal(context),
          child: Text(l10n.commonCancel),
        ),
      ),
      child: SafeArea(
        child: CustomScrollView(key: ValueKey(_type), slivers: slivers),
      ),
    );
  }

  Widget _message(String message) =>
      Padding(padding: const EdgeInsets.all(20), child: Text(message));

  Widget _choice({
    required Key key,
    required String title,
    String? subtitle,
    required IconData icon,
    required VoidCallback? onPressed,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: CupertinoButton(
        key: key,
        onPressed: onPressed,
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(icon, size: 24),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(CupertinoIcons.chevron_forward, size: 16),
          ],
        ),
      ),
    ),
  );
}
