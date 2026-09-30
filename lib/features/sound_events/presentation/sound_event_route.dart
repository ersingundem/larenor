import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/providers/server_providers.dart';
import '../data/core_sound_event_api.dart';
import '../data/sound_event_controller.dart';
import '../domain/sound_event_source_models.dart';
import 'sound_event_screen.dart';
import 'sound_event_source_screen.dart';

class SoundEventRoute extends ConsumerStatefulWidget {
  const SoundEventRoute({super.key, required this.gateCurrent});
  final bool Function() gateCurrent;
  @override
  ConsumerState<SoundEventRoute> createState() => _SoundEventRouteState();
}

class _SoundEventRouteState extends ConsumerState<SoundEventRoute> {
  ServerAccountController? _account;
  AppInteractionController? _interaction;
  CoreSoundEventApi? _api;
  SoundEventController? _controller;
  SoundSourceSetup? _sourceSetup;
  bool _showSourceSetup = false;
  bool _sourceSetupFailed = false;
  int _generation = 0;
  bool _loading = true, _failed = false;

  bool get _interactive => _interaction?.active ?? true;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider)
      ?..addListener(_accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_connect()));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (identical(next, _interaction)) return;
    _interaction?.removeListener(_interactionChanged);
    _interaction = next?..addListener(_interactionChanged);
  }

  bool _current(int generation) {
    if (!mounted || generation != _generation || !_interactive) return false;
    try {
      return widget.gateCurrent() && ModalRoute.of(context)?.isCurrent == true;
    } catch (_) {
      return false;
    }
  }

  void _interactionChanged() {
    if (!_interactive) _retire();
  }

  void _accountChanged() {
    if (_api case final api?
        when !identical(_account?.session, api.boundSession)) {
      _retire();
    }
  }

  void _retire() {
    if (!mounted) return;
    _generation++;
    _api?.retire();
    _controller?.dispose();
    _api = null;
    _controller = null;
    _sourceSetup = null;
    _showSourceSetup = false;
    _sourceSetupFailed = false;
    setState(() {
      _loading = false;
      _failed = true;
    });
  }

  Future<void> _connect() async {
    if (!_interactive || _account == null) return _retire();
    final generation = ++_generation;
    _api?.retire();
    _controller?.dispose();
    setState(() {
      _loading = true;
      _failed = false;
    });
    final api = CoreSoundEventApi(
      account: _account!,
      isCurrent: () => _current(generation),
    );
    _api = api;
    try {
      final snapshot = await api.bootstrap();
      if (!_current(generation) || !identical(_api, api)) {
        api.retire();
        return;
      }
      final controller = SoundEventController(
        api: api,
        authority: snapshot.authority,
        isCurrent: () => _current(generation) && identical(_api, api),
      );
      SoundSourceSetup? sourceSetup;
      var sourceSetupFailed = false;
      try {
        sourceSetup = await api.loadSourceSetup();
      } catch (_) {
        sourceSetupFailed = true;
      }
      if (!_current(generation) || !identical(_api, api)) {
        controller.dispose();
        api.retire();
        return;
      }
      setState(() {
        _controller = controller;
        _sourceSetup = sourceSetup;
        _sourceSetupFailed = sourceSetupFailed;
        _showSourceSetup =
            sourceSetup?.configuration == null && sourceSetup != null;
        _loading = false;
      });
    } catch (_) {
      if (_current(generation) && identical(_api, api)) {
        api.retire();
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _openSourceSetup() async {
    final api = _api;
    if (api == null || !_interactive) return;
    try {
      final value = await api.loadSourceSetup();
      if (!mounted || !identical(_api, api) || !_interactive) return;
      setState(() {
        _sourceSetup = value;
        _sourceSetupFailed = false;
        _showSourceSetup = true;
      });
    } catch (_) {
      if (mounted && identical(_api, api) && _interactive) {
        setState(() => _sourceSetupFailed = true);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _interaction?.removeListener(_interactionChanged);
    _account?.removeListener(_accountChanged);
    _api?.retire();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = Localizations.localeOf(context).languageCode == 'tr';
    final api = _api, setup = _sourceSetup;
    if (_showSourceSetup && api != null && setup != null) {
      return SoundEventSourceScreen(
        api: api,
        setup: setup,
        onConfigured: (value) {
          if (!mounted || !identical(_api, api)) return;
          setState(() {
            _sourceSetup = value;
            _sourceSetupFailed = false;
            _showSourceSetup = false;
          });
          if (value.configuration?.consentGranted == true) {
            _controller?.refreshSource();
          } else {
            _controller?.load();
          }
        },
        onCancel: setup.configuration == null
            ? null
            : () => setState(() => _showSourceSetup = false),
      );
    }
    if (_controller case final controller?) {
      return SoundEventScreen(
        controller: controller,
        onRefreshSource:
            controller.api is SoundEventSourceApi &&
                _sourceSetup?.configuration != null
            ? controller.refreshSource
            : null,
        onConfigureSource: () => unawaited(_openSourceSetup()),
        sourceSetupFailed: _sourceSetupFailed,
      );
    }
    return ServiceRootScaffold(
      title: tr ? 'Ses olayları' : 'Sound events',
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            children: [
              if (_loading)
                Semantics(
                  liveRegion: true,
                  label: tr
                      ? 'Ses olayları yükleniyor'
                      : 'Loading sound events',
                  child: const SizedBox(
                    height: 56,
                    child: Center(child: CupertinoActivityIndicator()),
                  ),
                )
              else if (_failed)
                SettingsActionTile(
                  buttonKey: const ValueKey('sound-event-route-retry'),
                  leading: const Icon(CupertinoIcons.refresh),
                  title: Text(tr ? 'Yeniden bağlan' : 'Reconnect'),
                  additionalInfo: Text(
                    tr ? 'Core, hesap, oturum veya rota doğrulanamadı.' : 'Core, account, session, or route could not be verified.',
                  ),
                  onTap: _interactive ? _connect : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
