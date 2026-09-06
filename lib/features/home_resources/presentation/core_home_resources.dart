import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../data/home_resources_api.dart';
import '../data/home_resources_controller.dart';
import '../domain/home_resource_models.dart';
import '../../settings/presentation/settings_gate_screen.dart';

/// This sliver shares the Core page scroll view and never opens HA adapters.
class CoreHomeResources extends ConsumerStatefulWidget {
  const CoreHomeResources({super.key});
  @override
  ConsumerState<CoreHomeResources> createState() => _CoreHomeResourcesState();
}

class _CoreHomeResourcesState extends ConsumerState<CoreHomeResources>
    with WidgetsBindingObserver {
  late final HomeResourcesController _controller;
  bool _foreground = true, _focused = true, _scheduled = false;
  int? _viewId;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _controller = HomeResourcesController(
      ref.read(homeSessionControllerProvider)!,
      ref.read(homeResourcesApiFactoryProvider),
      ref.read(homeResourcesClockProvider),
      _current,
    );
  }

  bool _current() =>
      mounted &&
      identical(ref.read(homeSessionControllerProvider), _controller.home) &&
      _foreground &&
      _focused &&
      _windowAvailable() &&
      (AppInteractionScope.maybeRead(context)?.active ?? true) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true;
  bool _windowAvailable() {
    final reading = ref.read(windowPolicySnapshotProvider);
    if (reading.isLoading || reading.hasError || !reading.hasValue) {
      return false;
    }
    final window = reading.requireValue;
    return !window.supported ||
        (window.isResumed &&
            window.hasWindowFocus &&
            !window.isPictureInPicture);
  }

  void _windowChanged() {
    if (!_windowAvailable()) _generation++;
    _controller.setVisible(_current());
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _focused = event.state == ViewFocusState.focused;
    if (!_focused) _generation++;
    _controller.setVisible(_current());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
    AppInteractionScope.maybeOf(context);
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
    _syncLater();
  }

  void _syncLater() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _controller.setVisible(_current());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _generation++;
    _controller.setVisible(_current());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    ref.listen(windowPolicySnapshotProvider, (_, _) => _windowChanged());
    _syncLater();
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (_, _) {
        if (!_current()) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        final epoch = _controller.epoch, generation = _generation;
        final interaction = AppInteractionScope.maybeRead(context),
            interactionEpoch = interaction?.epoch;
        bool current() =>
            _current() &&
            epoch == _controller.epoch &&
            generation == _generation &&
            identical(interaction, AppInteractionScope.maybeRead(context)) &&
            interaction?.epoch == interactionEpoch;
        Widget button(
          String key,
          String label,
          bool enabled,
          Future<void> Function() action,
        ) => CupertinoButton(
          key: ValueKey(key),
          minimumSize: const Size(48, 48),
          focusColor: CupertinoTheme.of(context).primaryColor,
          onPressed: !enabled
              ? null
              : () {
                  if (current()) unawaited(action());
                },
          child: Text(label, textAlign: TextAlign.center),
        );
        final visibleEntries = _controller.fresh
            ? (_controller.entries.toList()..sort((a, b) {
                final order = a.order.compareTo(b.order);
                return order == 0 ? a.id.compareTo(b.id) : order;
              }))
            : const <HomeResourceRecord>[];
        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.homeResourcesTitle,
                      style: CupertinoTheme.of(context)
                          .textTheme
                          .navTitleTextStyle,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(l10n.homeResourcesDescription),
                  const SizedBox(height: 8),
                  button(
                    'home-resources-refresh',
                    l10n.commonRefresh,
                    _controller.canRefresh,
                    _controller.refresh,
                  ),
                  if (_controller.canManage)
                    button('home-resources-manage', l10n.homeResourceAdminManage, true, () async {
                      if (!current() || !_controller.canManage) return;
                      await Navigator.of(context).push<void>(CupertinoPageRoute(builder: (_) =>
                        const SettingsGateScreen(initialDestination: SettingsGateDestination.homeResources)));
                    }),
                  if (_controller.busy)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.homeResourcesLoading,
                        key: const ValueKey('home-resources-loading'),
                      ),
                    )
                  else if (!_controller.fresh)
                    Text(l10n.homeCoreVerificationRequired)
                  else if (_controller.failure != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.homeResourcesError,
                        key: const ValueKey('home-resources-error'),
                      ),
                    )
                  else if (_controller.loaded && visibleEntries.isEmpty)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.homeResourcesEmpty,
                        key: const ValueKey('home-resources-empty'),
                      ),
                    ),
                ],
              ),
            ),
            SliverList.builder(
              key: const ValueKey('home-resources-list'),
              itemCount: visibleEntries.length,
              findChildIndexCallback: (key) {
                final index = visibleEntries.indexWhere(
                  (entry) => key == ValueKey('home-resource-${entry.id}'),
                );
                return index < 0 ? null : index;
              },
              itemBuilder: (context, index) {
                final entry = visibleEntries[index];
                final kind = entry.kind == HomeResourceKind.room
                    ? l10n.homeResourcesRoom
                    : l10n.homeResourcesResource;
                return Padding(
                  key: ValueKey('home-resource-${entry.id}'),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Semantics(
                    container: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.label,
                          style: CupertinoTheme.of(context).textTheme.textStyle
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(kind),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (_controller.nextAfter != null)
              SliverToBoxAdapter(
                child: button(
                  'home-resources-load-more',
                  l10n.homeResourcesLoadMore,
                  _controller.canLoadMore,
                  _controller.loadMore,
                ),
              ),
          ],
        );
      },
    );
  }
}
