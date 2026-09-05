import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../dashboard/domain/tile_config.dart';
import '../../health/data/health_configuration.dart';
import '../data/keenetic_config.dart';
import '../providers/keenetic_providers.dart';
import '../providers/keenetic_telemetry_providers.dart';
import 'keenetic_metric_presentation.dart';

/// Returns local widget configuration only. Opening the static choices makes
/// no router requests; selecting traffic explicitly reads interface inventory.
class KeeneticWidgetPickerScreen extends ConsumerStatefulWidget {
  const KeeneticWidgetPickerScreen({super.key});
  @override
  ConsumerState<KeeneticWidgetPickerScreen> createState() =>
      _KeeneticWidgetPickerScreenState();
}

class _KeeneticWidgetPickerScreenState
    extends ConsumerState<KeeneticWidgetPickerScreen> {
  KeeneticMetricKind _selected = KeeneticMetricKind.internetStatus;
  String? _interfaceId;
  KeeneticConfig? _account;
  bool _captured = false,
      _expired = false,
      _foreground = true,
      _submitted = false;
  int _generation = 0;
  late final AppLifecycleListener _lifecycle;
  static const _inventoryRequest = KeeneticMetricRequest(
    KeeneticMetricKind.interfaces,
  );

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (!mounted) return;
        setState(() {
          _foreground = state == AppLifecycleState.resumed;
          if (!_foreground) {
            _generation++;
            _interfaceId = null;
          }
        });
      },
    );
  }

  @override
  void dispose() {
    _generation++;
    _lifecycle.dispose();
    super.dispose();
  }

  bool _current(int generation) {
    if (!mounted ||
        !_foreground ||
        _expired ||
        _submitted ||
        generation != _generation) {
      return false;
    }
    final config = ref.read(keeneticConnectionProvider);
    return _captured &&
        !config.isLoading &&
        !config.hasError &&
        sameHealthConfiguration(_account, config.value);
  }

  bool _validInterface() {
    if (_interfaceId == null ||
        !ref.exists(keeneticMetricProvider(_inventoryRequest))) {
      return false;
    }
    final reading = ref.read(keeneticMetricProvider(_inventoryRequest));
    if (reading.isLoading || reading.hasError) return false;
    final snapshot = reading.value;
    final inventory = snapshot?.interfaces;
    if (snapshot == null ||
        snapshot.isPaused ||
        snapshot.connectionIssue != null ||
        inventory?.succeeded != true ||
        inventory?.readAt == null) {
      return false;
    }
    final age = DateTime.now().difference(inventory!.readAt!);
    return age >= Duration.zero &&
        age <= const Duration(seconds: 45) &&
        inventory.value!.any((item) => item.id == _interfaceId);
  }

  void _save(int generation) {
    if (!_current(generation) ||
        ModalRoute.of(context)?.isCurrent != true ||
        (_selected == KeeneticMetricKind.wanTraffic && !_validInterface())) {
      return;
    }
    _submitted = true;
    Navigator.pop(
      context,
      TileConfig(
        id: 'keenetic-${DateTime.now().microsecondsSinceEpoch}',
        type: TileType.keenetic,
        x: 0,
        y: 0,
        width: 2,
        height: 2,
        keeneticMetric: _selected,
        keeneticInterfaceId: _selected == KeeneticMetricKind.wanTraffic
            ? _interfaceId
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final config = ref.watch(keeneticConnectionProvider);
    if (!_captured && !config.isLoading && !config.hasError) {
      _captured = true;
      _account = config.value;
    }
    ref.listen(keeneticConnectionProvider, (_, next) {
      if (_captured &&
          (next.isLoading ||
              next.hasError ||
              !sameHealthConfiguration(_account, next.value))) {
        setState(() {
          _expired = true;
          _generation++;
          _interfaceId = null;
        });
      }
    });
    final generation = _generation;
    final active = _current(generation);
    final AsyncValue<KeeneticTelemetrySnapshot>? inventory =
        active &&
            _selected == KeeneticMetricKind.wanTraffic &&
            config.value != null &&
            TickerMode.valuesOf(context).enabled
        ? ref.watch(keeneticMetricProvider(_inventoryRequest))
        : null;
    final snapshot =
        inventory == null || inventory.isLoading || inventory.hasError
        ? null
        : inventory.value;
    final interfaces = snapshot?.interfaces.issue == null
        ? snapshot?.interfaces.value
        : null;
    final canSave =
        active &&
        (_selected != KeeneticMetricKind.wanTraffic || _validInterface());
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.keeneticAddWidget),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: canSave ? () => _save(generation) : null,
          child: Text(l10n.commonAdd),
        ),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.keeneticWidgetHint, style: AppText.subhead),
                        if (_expired) Text(l10n.keeneticMetricSessionChanged),
                        if (config.hasError) Text(l10n.healthReadError),
                        if (config.isLoading)
                          const CupertinoActivityIndicator(),
                        if (!config.isLoading &&
                            !config.hasError &&
                            config.value == null)
                          Text(l10n.commonNotConnected),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverList.list(
                    children: [
                      for (final kind in KeeneticMetricKind.values)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: CupertinoButton(
                            color: CupertinoColors
                                .secondarySystemGroupedBackground
                                .resolveFrom(context),
                            onPressed: active
                                ? () {
                                    if (_current(generation)) {
                                      setState(() {
                                        _selected = kind;
                                        _interfaceId = null;
                                        _generation++;
                                      });
                                    }
                                  }
                                : null,
                            child: Row(
                              children: [
                                Icon(keeneticMetricIcon(kind)),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    keeneticMetricTitle(l10n, kind),
                                    style: AppText.body.copyWith(
                                      color: CupertinoColors.label.resolveFrom(
                                        context,
                                      ),
                                    ),
                                  ),
                                ),
                                if (kind == _selected)
                                  const Icon(
                                    CupertinoIcons.check_mark_circled_solid,
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_selected == KeeneticMetricKind.wanTraffic) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.keeneticChooseInterface,
                            style: AppText.headline,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.keeneticSelectInterfaceHint,
                            style: AppText.footnote,
                          ),
                          if (inventory?.isLoading == true ||
                              snapshot?.isRefreshing == true)
                            const CupertinoActivityIndicator(),
                          if (inventory?.hasError == true)
                            Text(l10n.healthReadError),
                          if (snapshot?.connectionIssue != null ||
                              snapshot?.interfaces.issue != null)
                            Text(
                              keeneticReadFailureLabel(
                                l10n,
                                snapshot!.connectionIssue ??
                                    snapshot.interfaces.issue!,
                              ),
                            ),
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed:
                                active &&
                                    config.value != null &&
                                    snapshot != null &&
                                    !snapshot.isRefreshing
                                ? () {
                                    if (_current(generation)) {
                                      ref
                                          .read(
                                            keeneticTelemetryControllerProvider,
                                          )
                                          .refresh();
                                    }
                                  }
                                : null,
                            child: Text(l10n.commonRefresh),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (interfaces != null)
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      sliver: SliverList.builder(
                        itemCount: interfaces.length,
                        itemBuilder: (context, index) {
                          final item = interfaces[index];
                          return CupertinoListTile.notched(
                            title: Text(item.description ?? item.id),
                            subtitle: Text(
                              '${item.id} · ${item.address ?? l10n.commonUnknown}',
                            ),
                            trailing: item.id == _interfaceId
                                ? const Icon(CupertinoIcons.check_mark)
                                : null,
                            onTap: active
                                ? () {
                                    if (_current(generation)) {
                                      setState(() => _interfaceId = item.id);
                                    }
                                  }
                                : null,
                          );
                        },
                      ),
                    ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 28)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
