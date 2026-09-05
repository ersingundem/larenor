import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/network/server_bound_client.dart';
import '../../../../shared/widgets/action_status_indicator.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../dashboard/presentation/entity_picker_screen.dart';
import '../../../ha_client/data/models/ha_entity.dart';
import '../../../ha_client/providers/ha_client_providers.dart';
import '../../../ha_tools/presentation/ha_actions_screen.dart';
import '../../../health/data/health_configuration.dart';
import '../../../health/data/integration_health.dart';
import '../../../health/providers/ha_actions.dart';
import '../../../health/providers/health_providers.dart';
import '../data/movie_night_store.dart';
import '../domain/movie_night_preset.dart';
import '../domain/movie_night_runner.dart';

final movieNightStoreProvider = Provider((ref) => MovieNightStore());

/// Caller supplies an account/target guard and opens an actual playable item.
/// A series container should offer this action after an episode is selected.
class MovieNightLauncher extends ConsumerStatefulWidget {
  const MovieNightLauncher({
    super.key,
    required this.title,
    required this.onPlay,
    required this.isPlaybackCurrent,
    this.enabled = true,
  });
  final String title;
  final bool enabled;
  final Future<bool> Function() onPlay;
  final bool Function() isPlaybackCurrent;
  @override
  ConsumerState<MovieNightLauncher> createState() => _MovieNightLauncherState();
}

class _MovieNightLauncherState extends ConsumerState<MovieNightLauncher> {
  late final AppLifecycleListener _lifecycle;
  int _generation = 0;
  bool _foreground = true;
  bool _busy = false;
  String? _message;
  String? _activeEntity;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _foreground = state == AppLifecycleState.resumed;
        if (!_foreground) _generation++;
      },
    );
  }

  @override
  void dispose() {
    _generation++;
    _lifecycle.dispose();
    super.dispose();
  }

  bool _current(int generation, Object? connection) {
    if (!mounted) return false;
    final current = ref.read(connectionConfigProvider);
    return mounted &&
        _foreground &&
        generation == _generation &&
        !current.isLoading &&
        !current.hasError &&
        sameHealthConfiguration(connection, current.value) &&
        widget.isPlaybackCurrent();
  }

  Future<void> _launch() async {
    if (_busy ||
        !widget.enabled ||
        !_foreground ||
        !widget.isPlaybackCurrent()) {
      return;
    }
    final connection = ref.read(connectionConfigProvider).value;
    if (connection == null) return;
    final generation = ++_generation;
    bool current() => _current(generation, connection);
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _message = null;
      _activeEntity = null;
    });
    try {
      // User intent starts the HA reads. Merely opening media details does
      // not initialize the scene catalogue or entity subscription.
      await Future.wait([
        ref.read(entitiesProvider.future),
        ref.read(haActionsProvider.future),
      ]).timeout(const Duration(seconds: 20));
      if (!mounted || !current()) return;
      final saved = await ref.read(movieNightStoreProvider).read();
      if (!mounted || !current()) return;
      final baseUrl = parseServerUrl(connection.baseUrl).toString();
      final selected = await Navigator.of(context).push<MovieNightPreset>(
        CupertinoPageRoute(
          builder: (_) => _MovieNightSetupScreen(
            title: widget.title,
            serverUrl: baseUrl,
            initial: saved?.serverUrl == baseUrl ? saved : null,
            isCurrent: current,
          ),
        ),
      );
      if (selected == null || !current() || !widget.enabled) return;
      await ref
          .read(movieNightStoreProvider)
          .save(selected, isCurrent: current);
      if (!mounted || !current()) return;
      Future<void> activate(String id) async {
        final states = ref.read(entitiesProvider);
        final catalog = ref.read(haActionsProvider);
        final entity = states.value?[id];
        if (!current() ||
            states.isReloading ||
            states.hasError ||
            entity == null ||
            entity.state == 'unavailable' ||
            !MovieNightPreset.validEntity(id) ||
            catalog.isLoading ||
            catalog.hasError ||
            !(catalog.value?.any(
                  (action) =>
                      action.domain == entity.domain &&
                      action.service == 'turn_on',
                ) ??
                false) ||
            ref.read(integrationHealthStatusProvider(IntegrationId.ha)) !=
                HealthStatus.healthy) {
          throw StateError('Movie night scene is not ready');
        }
        setState(() => _activeEntity = id);
        await ref
            .read(haActionExecutorProvider)
            .execute(domain: entity.domain, service: 'turn_on', entityId: id);
      }

      final runner = MovieNightRunner(
        preset: selected,
        isCurrent: current,
        activate: activate,
        play: widget.onPlay,
      );
      final outcome = await runner.run();
      if (!mounted || !current()) return;
      setState(
        () => _message = switch (outcome) {
          MovieNightOutcome.finished => l10n.movieNightReturned,
          MovieNightOutcome.sceneFailed => l10n.movieNightSceneFailed,
          MovieNightOutcome.playbackFailed => l10n.movieNightPlaybackFailed,
          _ => l10n.movieNightCancelled,
        },
      );
      if (runner.canFinish) {
        final entity = ref
            .read(entitiesProvider)
            .value?[selected.finishEntityId];
        final finish = await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: Text(l10n.movieNightFinish),
            content: Text(
              l10n.movieNightFinishConfirm(
                entity?.friendlyName ?? selected.finishEntityId!,
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l10n.commonCancel),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(l10n.movieNightApply),
              ),
            ],
          ),
        );
        if (finish == true && current()) {
          final applied = await runner.finish();
          if (current()) {
            setState(
              () => _message = applied
                  ? l10n.movieNightSceneAccepted
                  : l10n.movieNightFinishFailed,
            );
          }
        }
      }
    } catch (_) {
      if (current()) setState(() => _message = l10n.movieNightSetupFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final connection = ref.watch(connectionConfigProvider);
    if (_busy) {
      ref.watch(haActionsProvider);
      ref.watch(
        entitiesProvider.select((state) => (state.isLoading, state.hasError)),
      );
      ref.watch(integrationHealthStatusProvider(IntegrationId.ha));
    }
    ref.listen(connectionConfigProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          !sameHealthConfiguration(previous?.value, next.value)) {
        _generation++;
        _message = null;
        _activeEntity = null;
      }
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CupertinoButton(
          padding: const EdgeInsets.symmetric(vertical: 12),
          onPressed:
              !widget.enabled ||
                  _busy ||
                  connection.isLoading ||
                  connection.value == null ||
                  !widget.isPlaybackCurrent()
              ? null
              : _launch,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy)
                const CupertinoActivityIndicator()
              else
                const Icon(CupertinoIcons.moon_stars),
              const SizedBox(width: 8),
              Flexible(child: Text(l10n.movieNightTitle)),
            ],
          ),
        ),
        if (connection.value == null) Text(l10n.movieNightNeedsHa),
        if (_message != null) Text(_message!),
        if (_activeEntity != null)
          ActionStatusIndicator(entityId: _activeEntity!),
      ],
    );
  }
}

class _MovieNightSetupScreen extends ConsumerStatefulWidget {
  const _MovieNightSetupScreen({
    required this.title,
    required this.serverUrl,
    required this.isCurrent,
    this.initial,
  });
  final String title;
  final String serverUrl;
  final MovieNightPreset? initial;
  final bool Function() isCurrent;
  @override
  ConsumerState<_MovieNightSetupScreen> createState() =>
      _MovieNightSetupScreenState();
}

class _MovieNightSetupScreenState
    extends ConsumerState<_MovieNightSetupScreen> {
  late String? _start = widget.initial?.startEntityId;
  late String? _finish = widget.initial?.finishEntityId;
  bool _submitted = false;
  Future<void> _pick(bool finish) async {
    if (!widget.isCurrent()) return;
    final states = ref.read(entitiesProvider);
    final catalog = ref.read(haActionsProvider);
    if (states.isReloading ||
        states.hasError ||
        catalog.isLoading ||
        catalog.hasError) {
      return;
    }
    final entity = await Navigator.of(context).push<HaEntity>(
      CupertinoPageRoute(
        builder: (_) => EntityPickerScreen(
          entities: (states.value?.values ?? const <HaEntity>[])
              .where(
                (entity) =>
                    MovieNightPreset.validEntity(entity.entityId) &&
                    entity.state != 'unavailable' &&
                    (catalog.value?.any(
                          (action) =>
                              action.domain == entity.domain &&
                              action.service == 'turn_on',
                        ) ??
                        false),
              )
              .toList(),
        ),
      ),
    );
    if (mounted && widget.isCurrent() && entity != null) {
      setState(() {
        if (finish) {
          _finish = entity.entityId;
        } else {
          _start = entity.entityId;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entities =
        ref.watch(entitiesProvider).value ?? const <String, HaEntity>{};
    ref.watch(connectionConfigProvider);
    ref.watch(integrationHealthStatusProvider(IntegrationId.ha));
    final valid =
        !_submitted &&
        widget.isCurrent() &&
        _start != null &&
        entities.containsKey(_start) &&
        entities[_start]?.state != 'unavailable';
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(l10n.movieNightTitle)),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              widget.title,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(l10n.movieNightExplanation),
            const SizedBox(height: 20),
            SettingsSection(
              children: [
                CupertinoListTile(
                  title: Text(l10n.movieNightStart),
                  subtitle: Text(
                    entities[_start]?.friendlyName ??
                        _start ??
                        l10n.movieNightChoose,
                  ),
                  trailing: const CupertinoListTileChevron(),
                  onTap: () => _pick(false),
                ),
                CupertinoListTile(
                  title: Text(l10n.movieNightFinishOptional),
                  subtitle: Text(
                    entities[_finish]?.friendlyName ??
                        _finish ??
                        l10n.movieNightNone,
                  ),
                  trailing: const CupertinoListTileChevron(),
                  onTap: () => _pick(true),
                ),
                if (_finish != null)
                  CupertinoListTile(
                    title: Text(l10n.movieNightClearFinish),
                    onTap: () => setState(() => _finish = null),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            CupertinoButton.filled(
              onPressed: valid
                  ? () {
                      if (widget.isCurrent()) {
                        if (_submitted) return;
                        _submitted = true;
                        Navigator.pop(
                          context,
                          MovieNightPreset(
                            serverUrl: widget.serverUrl,
                            startEntityId: _start!,
                            finishEntityId: _finish,
                          ),
                        );
                      }
                    }
                  : null,
              child: Text(l10n.movieNightStartAndPlay),
            ),
            if (!widget.isCurrent()) Text(l10n.movieNightCancelled),
          ],
        ),
      ),
    );
  }
}
