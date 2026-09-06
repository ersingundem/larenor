import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../data/home_people_providers.dart';
import 'home_people_widgets.dart';

/// A route returning from a child creates a fresh provider owner. Source,
/// account or container replacement permanently closes this mounted route.
class HomePeopleRoute extends ConsumerStatefulWidget {
  const HomePeopleRoute({
    super.key,
    required this.title,
    required this.builder,
    required this.gateCurrent,
    this.onExit,
    this.backKey = 'home-people-back',
  });
  final String title, backKey;
  final bool Function() gateCurrent;
  final Widget Function(HomePeopleOwner) builder;
  final VoidCallback? onExit;
  @override
  ConsumerState<HomePeopleRoute> createState() => _HomePeopleRouteState();
}

class _HomePeopleRouteState extends ConsumerState<HomePeopleRoute>
    with WidgetsBindingObserver {
  ProviderContainer? _container;
  HomeSessionController? _home;
  Object? _identity;
  int? _generation, _homeEpoch, _viewId;
  AppInteractionController? _interaction;
  HomePeopleOwner? _owner;
  bool _closed = false, _scheduled = false, _foreground = true, _focused = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  bool _binding() {
    if (!mounted || _closed) return false;
    try {
      if (_container == null ||
          !identical(
            ProviderScope.containerOf(context, listen: false),
            _container,
          ) ||
          !identical(ref.read(homeSessionControllerProvider), _home) ||
          _home?.runtimeIdentity != _identity ||
          _home?.account.generation != _generation ||
          _home?.interaction.epoch != _homeEpoch) {
        _closed = true;
        return false;
      }
      return true;
    } catch (_) {
      _closed = true;
      return false;
    }
  }

  bool _window() {
    final state = ref.read(windowPolicySnapshotProvider);
    if (state.isLoading || state.hasError || !state.hasValue) return false;
    final value = state.requireValue;
    return !value.supported ||
        value.isResumed && value.hasWindowFocus && !value.isPictureInPicture;
  }

  bool _current() {
    if (!_binding()) return false;
    try {
      return _foreground &&
          _focused &&
          _window() &&
          _interaction?.active == true &&
          _home?.source == HomeSource.verifiedCore &&
          _home?.busy == false &&
          _home?.failure == null &&
          _home?.interaction.active == true &&
          widget.gateCurrent() &&
          TickerMode.valuesOf(context).enabled &&
          ModalRoute.of(context)?.isCurrent == true;
    } catch (_) {
      return false;
    }
  }

  void _changed() {
    _owner?.synchronize();
    _schedule();
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final active = _current();
      if (!active) {
        if (_owner != null) {
          final old = _owner!;
          _owner = null;
          old.dispose();
          setState(() {});
        }
        return;
      }
      if (_owner == null || !_owner!.isCurrent) {
        _owner?.dispose();
        setState(
          () => _owner = HomePeopleOwner(
            isCurrent: _current,
            interaction: _interaction!,
          ),
        );
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final container = ProviderScope.containerOf(context, listen: false),
        interaction = AppInteractionScope.maybeOf(context),
        view = View.of(context).viewId;
    if (_container == null) {
      _container = container;
      _home = ref.read(homeSessionControllerProvider);
      _identity = _home?.runtimeIdentity;
      _generation = _home?.account.generation;
      _homeEpoch = _home?.interaction.epoch;
      _home?.addListener(_changed);
    }
    if (_interaction != null && !identical(_interaction, interaction))
      _closed = true;
    if (!identical(_interaction, interaction)) {
      _interaction?.removeListener(_changed);
      _interaction = interaction;
      interaction?.addListener(_changed);
    }
    if (_viewId != null && _viewId != view) {
      _owner?.retire();
      _focused = false;
    }
    _viewId = view;
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
    _changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _changed();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId != _viewId) return;
    _focused = event.state == ViewFocusState.focused;
    _changed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_changed);
    _home?.removeListener(_changed);
    _owner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    ref.listen(windowPolicySnapshotProvider, (_, _) => _changed());
    _schedule();
    final owner = _owner;
    if (owner != null && owner.isCurrent)
      return KeyedSubtree(key: ObjectKey(owner), child: widget.builder(owner));
    return PeoplePage(
      title: widget.title,
      backKey: widget.backKey,
      onBack: () => widget.onExit != null
          ? widget.onExit!()
          : Navigator.of(context).maybePop(),
      slivers: [
        peopleBlock([Text(AppLocalizations.of(context).homePeopleRequired)]),
      ],
    );
  }
}
