import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_session_controller.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../core_ha/data/core_ha_providers.dart';
import '../../core_ha/presentation/core_ha_route.dart';
import '../../core_ha/presentation/core_ha_widgets.dart';
import '../../dashboard/domain/tile_config.dart';
import '../../home_resources/data/home_resources_api.dart';
import '../../home_resources/data/home_resources_controller.dart';
import '../../home_resources/domain/home_resource_models.dart';

class CoreProxmoxWidgetPickerScreen extends StatelessWidget {
  const CoreProxmoxWidgetPickerScreen({super.key});

  @override
  Widget build(BuildContext context) => CoreHaRoute(
    title: AppLocalizations.of(context).coreProxmoxChooseResource,
    backKey: 'core-proxmox-picker-back',
    gateCurrent: () => true,
    builder: (owner) => _Picker(owner: owner),
  );
}

class _Picker extends ConsumerStatefulWidget {
  const _Picker({required this.owner});
  final CoreHaOwner owner;
  @override
  ConsumerState<_Picker> createState() => _PickerState();
}

class _PickerState extends ConsumerState<_Picker> {
  late final HomeResourcesController _controller;
  bool _returned = false;

  bool _current() => mounted && !_returned && widget.owner.isCurrent;

  @override
  void initState() {
    super.initState();
    final home = ref.read(homeSessionControllerProvider);
    _controller = HomeResourcesController(
      home!,
      ref.read(homeResourcesApiFactoryProvider),
      ref.read(homeResourcesClockProvider),
      _current,
    )..addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current()) _controller.setVisible(true);
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  void _choose(HomeResourceRecord entry) {
    if (!_current() ||
        !_controller.fresh ||
        entry.kind != HomeResourceKind.resource) {
      return;
    }
    _returned = true;
    Navigator.of(context).pop(
      TileConfig(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        type: TileType.proxmox,
        x: 0,
        y: 0,
        width: 3,
        height: 2,
        entityId: entry.id,
        title: entry.label,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final entries = _controller.fresh
        ? _controller.entries
              .where((entry) => entry.kind == HomeResourceKind.resource)
              .toList()
        : const <HomeResourceRecord>[];
    Widget button(String key, String label, VoidCallback? action) =>
        CoreHaButton(
          key: ValueKey(key),
          label: label,
          onPressed: action,
          isCurrent: _current,
        );
    return CoreHaPage(
      title: l.coreProxmoxChooseResource,
      backKey: 'core-proxmox-picker-back',
      onBack: _current() ? () => Navigator.of(context).maybePop() : null,
      slivers: [
        coreHaBlock([
          Text(l.coreProxmoxReadOnly),
          button(
            'core-proxmox-picker-refresh',
            l.commonRefresh,
            _controller.canRefresh
                ? () => unawaited(_controller.refresh())
                : null,
          ),
          if (_controller.busy)
            Semantics(liveRegion: true, child: Text(l.commonLoading))
          else if (_controller.failure != null)
            Semantics(liveRegion: true, child: Text(l.coreProxmoxOffline))
          else if (_controller.loaded && entries.isEmpty)
            Text(l.coreProxmoxEmpty),
          for (final entry in entries)
            button(
              'core-proxmox-picker-${entry.id}',
              entry.label,
              _current() ? () => _choose(entry) : null,
            ),
          if (_controller.nextAfter != null)
            button(
              'core-proxmox-picker-more',
              l.homeResourcesLoadMore,
              _controller.canLoadMore
                  ? () => unawaited(_controller.loadMore())
                  : null,
            ),
        ]),
      ],
    );
  }
}
