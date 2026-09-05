import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../app.dart';
import '../features/server/providers/server_providers.dart';
import 'home_session_controller.dart';
import 'home_source_store.dart';

final homeSourceStoreProvider = Provider<HomeSourcePersistence>(
  (_) => SharedPreferencesHomeSourceStore(),
);

/// Keeps account/source ownership outside a parentless application container.
/// All appearance, PIN, power, router and home providers share that container.
class HomeSessionScope extends ConsumerStatefulWidget {
  const HomeSessionScope({super.key, this.runtimeOverrides = const []});
  final List<Override> runtimeOverrides;

  @override
  ConsumerState<HomeSessionScope> createState() => _HomeSessionScopeState();
}

class _HomeSessionScopeState extends ConsumerState<HomeSessionScope> {
  late final HomeSessionController _controller;
  late ProviderContainer _runtime;
  late Object _identity;
  bool _retiring = false;

  @override
  void initState() {
    super.initState();
    _controller = HomeSessionController(
      store: ref.read(homeSourceStoreProvider),
      account: ref.read(serverAccountControllerProvider),
    );
    _createRuntime();
    _controller.addListener(_changed);
    unawaited(_controller.initialize());
  }

  void _createRuntime() {
    _identity = _controller.runtimeIdentity;
    _runtime = ProviderContainer(
      overrides: [
        ...widget.runtimeOverrides,
        serverAccountControllerProvider.overrideWithValue(_controller.account),
        homeSessionControllerProvider.overrideWithValue(_controller),
      ],
    );
    _controller.runtimeMounted(_identity);
  }

  void _changed() {
    if (!mounted || _retiring || _identity == _controller.runtimeIdentity)
      return;
    setState(() => _retiring = true);
    // First unmount every route/dialog and their consumers; only then dispose
    // their provider container. A later identity wins while this frame closes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runtime.dispose();
      _createRuntime();
      setState(() => _retiring = false);
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _runtime.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _retiring
      ? const SizedBox.expand()
      : UncontrolledProviderScope(
          key: ValueKey(_identity),
          container: _runtime,
          child: const LarenorApp(),
        );
}
