import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../providers/server_providers.dart';
import '../../music_retained/presentation/server_music_retained_screen.dart';
import '../data/server_media_preparations_controller.dart';
import '../domain/server_media_preparation_models.dart';
import 'server_media_inspections_screen.dart';

/// One durable preparation, accessed through PIN-protected Server settings.
/// No installation or provider credential entry is exposed.
class ServerMediaPreparationsScreen extends ConsumerStatefulWidget {
  const ServerMediaPreparationsScreen({super.key});
  @override
  ConsumerState<ServerMediaPreparationsScreen> createState() =>
      _ServerMediaPreparationsScreenState();
}

class _ServerMediaPreparationsScreenState
    extends MediaSessionState<ServerMediaPreparationsScreen> {
  late final ServerAccountController _account;
  late final ServerMediaPreparationsController _media;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  Route<bool>? _dialog;
  bool _visible = true,
      _expired = false,
      _loaded = false,
      _pinReady = false,
      _wasCurrent = true;
  bool get _active =>
      !_expired &&
      _visible &&
      _pinReady &&
      sessionCurrent(sessionGeneration) &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      (ModalRoute.of(context)?.isCurrent == true || _dialog?.isCurrent == true);
  bool get _enabled => _active && !_media.busy;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _media = ServerMediaPreparationsController(_account);
    _account.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) ||
        _account.working ||
        _account.session?.user.canAdminister != true) {
      _expire();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = ticker;
      _visible = ticker.value.enabled;
      ticker.addListener(_visibilityChanged);
    }
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_wasCurrent && !current && _dialog == null) _expire();
    _wasCurrent = current;
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  @override
  void clearPendingInteraction() => _expire();
  void _expire() {
    if (!mounted) return;
    final wasBusy = _media.busy;
    _expired = true;
    sessionGeneration++;
    final route = _dialog;
    _dialog = null;
    void retire() {
      if (!mounted) return;
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
      _clearFields();
      _media.invalidate();
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => retire());
    } else {
      retire();
    }
    if (wasBusy && !_account.working) unawaited(_account.cancelPending());
  }

  @override
  void dispose() {
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    for (final field in _fields.values) {
      field.dispose();
    }
    _media.dispose();
    super.dispose();
  }

  bool Function() _capture() {
    final epoch = sessionGeneration;
    return () => mounted && sessionCurrent(epoch) && _active;
  }

  VoidCallback _callback(FutureOr<void> Function(bool Function()) action) {
    final current = _capture();
    return () {
      if (current()) action(current);
    };
  }

  Future<void> _load(bool Function() current) => _media.load(current: current);
  Future<void> _cancel(bool Function() current) async {
    final selected = _media.selected;
    if (!_enabled ||
        selected == null ||
        !selected.prepared ||
        _media.cancelNeedsRefresh ||
        _dialog != null) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    late final CupertinoDialogRoute<bool> route;
    route = CupertinoDialogRoute<bool>(
      context: context,
      builder: (dialogContext) {
        if (ModalRoute.isCurrentOf(dialogContext) != true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && identical(_dialog, route) && !route.isCurrent) {
              _expire();
            }
          });
        }
        bool valid() =>
            current() && identical(_dialog, route) && route.isCurrent;
        return CupertinoAlertDialog(
          title: Text(l10n.serverMediaCancelTitle),
          content: Text(l10n.serverMediaCancelBody),
          actions: [
            CupertinoDialogAction(
              onPressed: () {
                if (valid()) Navigator.pop(dialogContext, false);
              },
              child: Text(l10n.commonBack),
            ),
            CupertinoDialogAction(
              key: const ValueKey('media-cancel-confirm'),
              isDestructiveAction: true,
              onPressed: () {
                if (valid()) Navigator.pop(dialogContext, true);
              },
              child: Text(l10n.serverMediaCancel),
            ),
          ],
        );
      },
    );
    _dialog = route;
    final confirmed = await Navigator.of(context).push(route);
    if (identical(_dialog, route)) _dialog = null;
    // A confirmation belongs to the exact record and revision reviewed.
    if (confirmed == true &&
        current() &&
        _media.selected?.id == selected.id &&
        _media.selected?.revision == selected.revision) {
      await _media.cancelSelected(current: current);
    }
  }

  Future<void> _openInspections(
    bool Function() current, [
    ServerMediaPreparation? preparation,
  ]) async {
    if (!_enabled || !current()) return;
    final plan = preparation?.plan ?? _media.preparations.firstOrNull?.plan;
    final identity = plan == null
        ? null
        : ServerContext.fromJson({
            'schemaVersion': 1,
            'coreId': plan.coreId,
            'homeId': plan.homeId,
          });
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => ServerMediaInspectionsScreen(
          preparation: preparation,
          context: identity,
        ),
      ),
    );
  }

  Future<void> _openMusicStatus(bool Function() current) async {
    if (!_enabled || !current()) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => const ServerMusicRetainedScreen(),
      ),
    );
  }

  final _fields = {
    'instanceName': TextEditingController(text: 'larenor'),
    'dataRootId': TextEditingController(text: 'appdata'),
    'libraryRootId': TextEditingController(text: 'library'),
    'musicRootId': TextEditingController(),
  };
  String _platform = 'linux/amd64';
  MediaPreparationSettings? get _settings {
    try {
      return MediaPreparationSettings.fromJson({
        for (final entry in _fields.entries)
          entry.key: entry.key == 'musicRootId' && entry.value.text.isEmpty
              ? null
              : entry.value.text,
      });
    } catch (_) {
      return null;
    }
  }

  void _clearFields() {
    for (final field in _fields.values) {
      field.clear();
    }
  }

  Future<void> _new(bool Function() current) async {
    await _media.prepareDraft(current: current);
    if (!current() || !_media.canCreate) return;
    _fields['instanceName']!.text = 'larenor';
    _fields['dataRootId']!.text = 'appdata';
    _fields['libraryRootId']!.text = 'library';
    _fields['musicRootId']!.clear();
    setState(() {
      _platform = 'linux/amd64';
    });
  }

  Future<void> _create(bool Function() current) async {
    final settings = _settings;
    if (settings == null) return;
    await _media.create(
      platform: _platform,
      settings: settings,
      current: current,
    );
    if (current() && !_media.canCreate) _clearFields();
  }

  String _failure(AppLocalizations l, String code) => switch (code) {
    'unauthorized' => l.serverFailureAuthentication,
    'forbidden' || 'password_change_required' => l.serverFailurePermission,
    'rate_limited' => l.serverFailureRateLimit,
    'media_preparation_conflict' => l.serverMediaNameConflict,
    'media_catalog_changed' => l.serverMediaCatalogChanged,
    'media_context_changed' => l.serverMediaContextChanged,
    'media_preparation_limit_reached' => l.serverMediaCapacity,
    'media_preparation_storage_unavailable' => l.serverMediaStorageUnavailable,
    'revision_conflict' => l.serverMediaRevisionConflict,
    _ => l.serverFailureConnection,
  };
  String _date(AppLocalizations l, DateTime time) =>
      DateFormat.yMd(l.localeName).add_Hm().format(time.toLocal());
  String _service(AppLocalizations l, String id) => switch (id) {
    'qbittorrent' => 'qBittorrent',
    'sonarr' => 'Sonarr',
    'radarr' => 'Radarr',
    'jellyfin' => 'Jellyfin',
    'seerr' => 'Seerr',
    _ => l.serverPluginsIntegratedMusic,
  };
  Widget _section(String title, List<Widget> children) => SettingsSection(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: AppText.headline),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    ],
  );
  Widget _button(
    String key,
    String label,
    FutureOr<void> Function(bool Function()) action, {
    bool allowed = true,
  }) => CupertinoButton(
    key: ValueKey(key),
    minimumSize: const Size(48, 48),
    onPressed: _enabled && allowed ? _callback(action) : null,
    child: Text(label),
  );

  Widget _seerrProgress(AppLocalizations l) {
    final value = _media.seerrConvergence;
    final failure = _media.seerrFailure;
    if (failure != null) {
      return _section(l.serverSeerrProgressTitle, [
        Semantics(
          liveRegion: true,
          child: Text(l.serverSeerrProgressUnavailable),
        ),
        _button(
          'media-seerr-recover',
          l.serverSeerrRecover,
          (current) => _media.refreshSelected(current: current),
        ),
      ]);
    }
    const phases = [
      'request',
      'bootstrap',
      'arr_wiring',
      'initialize',
      'verified',
    ];
    final labels = [
      l.serverSeerrPhaseRequest,
      l.serverSeerrPhaseBootstrap,
      l.serverSeerrPhaseArr,
      l.serverSeerrPhaseInitialize,
      l.serverSeerrPhaseVerified,
    ];
    final rank = switch (value?.phase) {
      'bootstrap' => 1,
      'arr_wiring' => 2,
      'initialize' => 3,
      'verified' => 4,
      _ => 0,
    };
    final failed = value?.needsRecovery == true;
    final cancelled = value?.cancelled == true;
    String status(int index) {
      if (value == null) {
        return index == 0
            ? l.serverSeerrProgressWaiting
            : l.serverSeerrProgressPending;
      }
      final complete = switch (index) {
        0 => true,
        1 => rank >= 2,
        2 => value.arrWired,
        3 => value.initialized,
        _ => value.state == 'succeeded',
      };
      if (cancelled && index == rank) {
        return l.serverSeerrProgressCancelled;
      }
      if (failed && index == rank) return l.serverSeerrProgressNeedsAttention;
      if (complete) return l.serverSeerrProgressComplete;
      if (!cancelled && index == rank) return l.serverSeerrProgressWorking;
      return l.serverSeerrProgressPending;
    }

    ({IconData icon, Color color}) visual(String status) {
      if (status == l.serverSeerrProgressComplete) {
        return (
          icon: CupertinoIcons.check_mark_circled_solid,
          color: CupertinoColors.systemGreen.resolveFrom(context),
        );
      }
      if (status == l.serverSeerrProgressNeedsAttention ||
          status == l.serverSeerrProgressCancelled) {
        return (
          icon: status == l.serverSeerrProgressCancelled
              ? CupertinoIcons.xmark_circle_fill
              : CupertinoIcons.exclamationmark_triangle_fill,
          color: CupertinoColors.systemRed.resolveFrom(context),
        );
      }
      return (
        icon: CupertinoIcons.circle_fill,
        color:
            (status == l.serverSeerrProgressWorking
                    ? CupertinoColors.systemBlue
                    : CupertinoColors.systemOrange)
                .resolveFrom(context),
      );
    }

    return _section(l.serverSeerrProgressTitle, [
      Text(l.serverSeerrProgressBody),
      const SizedBox(height: 8),
      for (var index = 0; index < phases.length; index++)
        Builder(
          builder: (context) {
            final rowStatus = status(index);
            final rowVisual = visual(rowStatus);
            return Semantics(
              key: ValueKey('media-seerr-phase-${phases[index]}'),
              label: '${labels[index]}: $rowStatus',
              liveRegion: (failed || cancelled) && index == rank,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Icon(rowVisual.icon, color: rowVisual.color, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(labels[index], style: AppText.subhead),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        rowStatus,
                        textAlign: TextAlign.end,
                        style: TextStyle(color: rowVisual.color),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      if (failed) ...[
        const SizedBox(height: 8),
        Semantics(liveRegion: true, child: Text(l.serverSeerrProgressPartial)),
        _button(
          'media-seerr-recover',
          l.serverSeerrRecover,
          (current) => _media.refreshSelected(current: current),
        ),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    _pinReady = !pin.isLoading && !pin.hasError;
    ref.listen(pinLockProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          (previous?.hasValue == true && previous?.value != next.value)) {
        _expire();
      }
    });
    if (_active && !_loaded) {
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active) unawaited(_load(_capture()));
      });
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l.serverMediaTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _media,
          builder: (context, _) {
            if (!_active) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _account.session?.user.canAdminister == true
                        ? l.serverOpenFromSettings
                        : l.serverFailurePermission,
                  ),
                ),
              );
            }
            final selected = _media.selected;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(l.serverMediaIntro),
                    ),
                    if (_media.busy)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: CupertinoActivityIndicator(),
                      ),
                    if (_media.failure != null)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(_failure(l, _media.failure!)),
                        ),
                      ),
                    if (_media.canRetryCreate)
                      _section(l.serverMediaRecovery, [
                        Text(l.serverMediaRecoveryBody),
                        _button(
                          'media-recover',
                          l.serverMediaRecover,
                          (current) => _media.retryCreate(current: current),
                        ),
                      ]),
                    if (selected != null)
                      ..._details(l, selected)
                    else if (_media.context != null && !_media.canRetryCreate)
                      _draft(l)
                    else ...[
                      _section(l.serverMediaHistory, [
                        Wrap(
                          children: [
                            _button(
                              'media-new',
                              l.serverMediaNew,
                              _new,
                              allowed: !_media.canRetryCreate,
                            ),
                            _button('media-refresh', l.commonRefresh, _load),
                            _button(
                              'media-inspections-history',
                              l.serverMediaInspectionsHistory,
                              _openInspections,
                            ),
                            _button(
                              'media-music-core',
                              l.serverMusicRetainedTitle,
                              _openMusicStatus,
                            ),
                          ],
                        ),
                        if (_media.preparations.isEmpty && !_media.busy)
                          Text(l.serverMediaEmpty),
                      ]),
                      for (final record in _media.preparations)
                        _section(record.plan.settings.instanceName, [
                          Text(
                            '${record.plan.platform} · ${_date(l, record.createdAt)}',
                          ),
                          Text(
                            record.prepared
                                ? l.serverMediaPrepared
                                : l.serverMediaCancelled,
                          ),
                          _button(
                            'media-view-${record.id}',
                            l.serverMediaView,
                            (current) =>
                                _media.select(record, current: current),
                          ),
                        ]),
                      if (_media.nextBefore != null &&
                          _media.preparations.length <
                              ServerMediaPreparationsController.maximumHistory)
                        _button(
                          'media-more',
                          l.serverAdminMore,
                          (current) => _media.loadMore(current: current),
                        ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _fieldLabel(AppLocalizations l, String key) => switch (key) {
    'instanceName' => l.serverPluginsSettingInstanceName,
    'dataRootId' => l.serverPluginsSettingDataRootId,
    'libraryRootId' => l.serverPluginsSettingLibraryRootId,
    _ => l.serverPluginsSettingMusicRootId,
  };
  Widget _draft(AppLocalizations l) => _section(l.serverMediaNew, [
    Text(l.serverMediaComponents),
    Text(l.serverMediaSettingsHelp),
    const SizedBox(height: 16),
    Text(l.serverPluginsPlatformChoice, style: AppText.subhead),
    const SizedBox(height: 8),
    CupertinoSlidingSegmentedControl<String>(
      groupValue: _platform,
      children: const {
        'linux/amd64': Text('AMD64'),
        'linux/arm64': Text('ARM64'),
      },
      onValueChanged: (value) {
        if (_enabled && value != null) {
          setState(() {
            _platform = value;
          });
        }
      },
    ),
    for (final entry in _fields.entries)
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_fieldLabel(l, entry.key)),
            const SizedBox(height: 6),
            Semantics(
              label: _fieldLabel(l, entry.key),
              child: CupertinoTextField(
                key: ValueKey('media-${entry.key}'),
                controller: entry.value,
                enabled: _enabled,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: entry.key == 'instanceName' ? 20 : 32,
                textInputAction: TextInputAction.next,
                onChanged: (_) {
                  if (_active) setState(() {});
                },
              ),
            ),
          ],
        ),
      ),
    if (_settings == null) Text(l.serverMediaInvalidSettings),
    Wrap(
      children: [
        _button(
          'media-create',
          l.serverMediaCreate,
          _create,
          allowed: _media.canCreate && _settings != null,
        ),
        _button('media-draft-close', l.commonBack, (_) {
          _clearFields();
          _media.closeDraft();
        }),
      ],
    ),
  ]);
  List<Widget> _details(AppLocalizations l, ServerMediaPreparation record) => [
    _section(record.plan.settings.instanceName, [
      Semantics(
        liveRegion: true,
        child: Text(
          record.prepared ? l.serverMediaPrepared : l.serverMediaCancelled,
          style: AppText.headline,
        ),
      ),
      Text(l.serverMediaNotInstalled),
      Text(record.plan.platform),
      Text('${l.serverMediaCreated}: ${_date(l, record.createdAt)}'),
      if (!record.catalogCurrent) Text(l.serverMediaHistoricalCatalog),
      if (_media.cancelNeedsRefresh) Text(l.serverMediaRevisionConflict),
      Wrap(
        children: [
          _button(
            'media-list',
            l.serverJobsBackToHistory,
            (_) => _media.showList(),
          ),
          _button(
            'media-refresh-selected',
            l.commonRefresh,
            (current) => _media.refreshSelected(current: current),
          ),
          _button(
            'media-inspect',
            l.serverMediaInspectionsLaunch,
            (current) => _openInspections(current, record),
            allowed: record.prepared && record.catalogCurrent,
          ),
          if (record.prepared)
            _button(
              'media-cancel',
              l.serverMediaCancel,
              _cancel,
              allowed: !_media.cancelNeedsRefresh,
            ),
        ],
      ),
    ]),
    _seerrProgress(l),
    _section(l.serverMediaRequirements, [
      Text(l.serverMediaBlockers),
      Text(l.serverMediaResources),
      Text(
        '${record.plan.memoryMiB} MiB RAM · ${record.plan.minimumDiskMiB} MiB',
      ),
      Text(
        '${l.serverMediaCpu}: ${record.plan.cpuMillis} · ${l.serverMediaPids}: ${record.plan.pidsLimit}',
      ),
    ]),
    _section(l.serverMediaPlannedComponents, [
      Text(l.serverMediaPlannedSteps),
      for (final component in record.plan.components)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_service(l, component.serviceId), style: AppText.headline),
              Text(component.plan.image.tag),
              Text(component.plan.instanceName, style: AppText.footnote),
            ],
          ),
        ),
    ]),
  ];
}
