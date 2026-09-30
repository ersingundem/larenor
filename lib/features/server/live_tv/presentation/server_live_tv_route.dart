import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../core/home_session_controller.dart';
import '../../../../core/home_source_store.dart';
import '../data/server_live_tv_controller.dart';
import '../domain/server_live_tv_models.dart';

final class ServerLiveTvRoute extends ConsumerStatefulWidget {
  const ServerLiveTvRoute({super.key});
  @override
  ConsumerState<ServerLiveTvRoute> createState() => _ServerLiveTvRouteState();
}

final class _ServerLiveTvRouteState extends ConsumerState<ServerLiveTvRoute> {
  HomeSessionController? _home;
  AppInteractionController? _interaction;
  Object? _identity;
  int? _generation, _homeEpoch;
  ServerLiveTvController? _controller;
  bool _requested = false;

  bool _current() {
    final home = _home;
    return mounted &&
        home != null &&
        identical(ref.read(homeSessionControllerProvider), home) &&
        identical(home.runtimeIdentity, _identity) &&
        home.account.generation == _generation &&
        home.interaction.epoch == _homeEpoch &&
        (_interaction?.active ?? true) &&
        home.source == HomeSource.verifiedCore &&
        !home.busy &&
        home.failure == null &&
        home.interaction.active &&
        home.account.session?.context != null &&
        home.account.session?.sessionFamilyId != null &&
        home.account.session?.user.mustChangePassword == false &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
  }

  void _changed() {
    if (!mounted) return;
    if (!_current()) {
      _controller?.dispose();
      _controller = null;
      _requested = false;
    } else {
      _controller ??= ServerLiveTvController(_home!.account);
      _loadOnce();
    }
    setState(() {});
  }

  void _loadOnce() {
    if (_requested || _controller == null || !_current()) return;
    _requested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current()) _controller?.load(current: _current);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final home = ref.read(homeSessionControllerProvider);
    final interaction = AppInteractionScope.maybeOf(context);
    if (_home == null && home != null) {
      _home = home;
      _identity = home.runtimeIdentity;
      _generation = home.account.generation;
      _homeEpoch = home.interaction.epoch;
      home.addListener(_changed);
    }
    if (!identical(_interaction, interaction)) {
      _interaction?.removeListener(_changed);
      _interaction = interaction;
      interaction?.addListener(_changed);
    }
    if (_controller == null && _current()) {
      _controller = ServerLiveTvController(_home!.account);
    }
    _loadOnce();
  }

  @override
  void dispose() {
    _interaction?.removeListener(_changed);
    _home?.removeListener(_changed);
    _controller?.dispose();
    super.dispose();
  }

  bool get _tr => Localizations.localeOf(context).languageCode == 'tr';

  String _error(String code) => switch (code) {
    'live_tv_source_unavailable' =>
      _tr
          ? 'Canlı TV kaynağı henüz yapılandırılmadı.'
          : 'The live TV source is not configured.',
    'live_tv_recording_conflict' =>
      _tr
          ? 'Bu saatte kullanılabilir tuner yok.'
          : 'No tuner is available at that time.',
    'live_tv_quota_exceeded' =>
      _tr
          ? 'Kayıt kotası bu program için yeterli değil.'
          : 'The recording quota is too small for this programme.',
    'live_tv_source_changed' ||
    'live_tv_recording_changed' ||
    'live_tv_authority_changed' =>
      _tr
          ? 'Yayın bilgisi değişti. Listeyi yenileyin.'
          : 'The broadcast changed. Refresh the guide.',
    'connection_failed' =>
      _tr ? 'Core bağlantısı kurulamadı.' : 'Could not reach Core.',
    _ => _tr ? 'İşlem tamamlanamadı.' : 'The operation could not be completed.',
  };

  Future<bool> _confirm(String title, String detail) async =>
      await showCupertinoDialog<bool>(
        context: context,
        builder: (dialog) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(_tr ? 'Vazgeç' : 'Cancel'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(_tr ? 'Onayla' : 'Confirm'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(_tr ? 'Canlı TV' : 'Live TV'),
        ),
        child: const Center(child: CupertinoActivityIndicator()),
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        return CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(
            middle: Text(_tr ? 'Canlı TV ve Kayıtlar' : 'Live TV & Recordings'),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: controller.busy || !_current()
                  ? null
                  : () => controller.load(current: _current),
              child: const Icon(CupertinoIcons.refresh),
            ),
          ),
          child: SafeArea(
            child: snapshot == null
                ? controller.sourceSetupLoaded && controller.canConfigure
                      ? _LiveTvSourceSetup(
                          options: controller.sourceOptions,
                          busy: controller.busy,
                          turkish: _tr,
                          failure: controller.failure == null
                              ? null
                              : _error(controller.failure!),
                          onConfigure:
                              (service, kind, timeZone, quotaBytes) async {
                                if (!_current()) return;
                                await controller.configureJellyfin(
                                  service: service,
                                  providerKind: kind,
                                  timeZone: timeZone,
                                  quotaBytes: quotaBytes,
                                  current: _current,
                                );
                              },
                          onRetry: () => controller.load(current: _current),
                        )
                      : _EmptyState(
                          busy: controller.busy,
                          message: controller.failure == null
                              ? (_tr
                                    ? 'Program rehberi yükleniyor…'
                                    : 'Loading programme guide…')
                              : _error(controller.failure!),
                          onRetry: () => controller.load(current: _current),
                          retryLabel: _tr ? 'Yeniden dene' : 'Retry',
                        )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 36),
                    children: [
                      _SourceSummary(snapshot: snapshot, turkish: _tr),
                      if (controller.failure != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error(controller.failure!),
                          style: const TextStyle(
                            color: CupertinoColors.systemRed,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        _tr ? 'Kayıtlar' : 'Recordings',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (snapshot.recordings.isEmpty)
                        Text(
                          _tr
                              ? 'Henüz kayıt planlanmadı.'
                              : 'No recordings are scheduled.',
                        ),
                      for (final recording in snapshot.recordings)
                        _RecordingCard(
                          recording: recording,
                          snapshot: snapshot,
                          turkish: _tr,
                          busy: controller.busy,
                          onCancel: recording.active
                              ? () async {
                                  if (await _confirm(
                                        _tr
                                            ? 'Kaydı iptal et'
                                            : 'Cancel recording',
                                        recording.title,
                                      ) &&
                                      _current()) {
                                    await controller.cancel(
                                      recording,
                                      current: _current,
                                    );
                                  }
                                }
                              : null,
                          onRestart:
                              recording.state ==
                                  ServerLiveTvRecordingState.interrupted
                              ? () async {
                                  if (await _confirm(
                                        _tr
                                            ? 'Kaydı yeniden başlat'
                                            : 'Restart recording',
                                        recording.title,
                                      ) &&
                                      _current()) {
                                    await controller.restart(
                                      recording,
                                      current: _current,
                                    );
                                  }
                                }
                              : null,
                        ),
                      const SizedBox(height: 24),
                      Text(
                        _tr ? 'Program rehberi' : 'Programme guide',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (snapshot.programmes.isEmpty)
                        Text(
                          _tr ? 'Rehberde program yok.' : 'The guide is empty.',
                        ),
                      for (final programme in snapshot.programmes)
                        _ProgrammeCard(
                          programme: programme,
                          snapshot: snapshot,
                          turkish: _tr,
                          busy: controller.busy,
                          onSchedule:
                              snapshot.recordingFor(programme.id) == null &&
                                  programme.endsAt.isAfter(
                                    DateTime.now().toUtc(),
                                  )
                              ? () async {
                                  final local = snapshot.timeZone.local(
                                    programme.startsAt,
                                  );
                                  final detail =
                                      '${programme.channelName} · ${DateFormat('dd MMM HH:mm').format(local)} ${snapshot.timeZone.name}';
                                  if (await _confirm(
                                        _tr
                                            ? 'Kaydı planla'
                                            : 'Schedule recording',
                                        '$detail\n${programme.title}',
                                      ) &&
                                      _current()) {
                                    await controller.schedule(
                                      programme,
                                      current: _current,
                                    );
                                  }
                                }
                              : null,
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

final class _LiveTvSourceSetup extends StatefulWidget {
  const _LiveTvSourceSetup({
    required this.options,
    required this.busy,
    required this.turkish,
    required this.failure,
    required this.onConfigure,
    required this.onRetry,
  });

  final List<ServerLiveTvSourceOption> options;
  final bool busy, turkish;
  final String? failure;
  final Future<void> Function(ServerLiveTvSourceOption, String, String, int)
  onConfigure;
  final VoidCallback onRetry;

  @override
  State<_LiveTvSourceSetup> createState() => _LiveTvSourceSetupState();
}

final class _LiveTvSourceSetupState extends State<_LiveTvSourceSetup> {
  final _timeZone = TextEditingController(text: 'Etc/UTC');
  String? _serviceId;
  String _kind = 'iptv';
  int _quota = 10737418240;
  bool _showServicePicker = false;

  @override
  void didUpdateWidget(covariant _LiveTvSourceSetup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_serviceId != null &&
        !widget.options.any((item) => item.serviceId == _serviceId)) {
      _serviceId = null;
    }
  }

  @override
  void dispose() {
    _timeZone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedId =
        _serviceId ??
        (widget.options.isEmpty ? null : widget.options.first.serviceId);
    final selected = widget.options
        .cast<ServerLiveTvSourceOption?>()
        .firstWhere(
          (item) => item?.serviceId == selectedId,
          orElse: () => null,
        );
    return ListView(
      key: const ValueKey('live-tv-source-setup'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 36),
      children: [
        Text(
          widget.turkish ? 'Canlı TV kaynağı' : 'Live TV source',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          widget.turkish
              ? 'Kimliği doğrulanmış Jellyfin bağlantısını seçin. Jellyfin üzerinde tuner ve program rehberi önceden etkin olmalıdır.'
              : 'Choose an authenticated Jellyfin connection. A tuner and programme guide must already be enabled in Jellyfin.',
        ),
        if (widget.failure != null) ...[
          const SizedBox(height: 12),
          Text(
            widget.failure!,
            style: const TextStyle(color: CupertinoColors.systemRed),
          ),
        ],
        const SizedBox(height: 18),
        if (widget.options.isEmpty) ...[
          Text(
            widget.turkish
                ? 'Uygun Jellyfin bağlantısı bulunamadı. Yönetici ayarlarından Jellyfin 10.11 bağlantısını ekleyip doğrulayın.'
                : 'No eligible Jellyfin connection was found. Add and verify a Jellyfin 10.11 connection in Admin settings.',
          ),
          const SizedBox(height: 12),
          CupertinoButton(
            key: const ValueKey('live-tv-source-retry'),
            onPressed: widget.busy ? null : widget.onRetry,
            child: Text(widget.turkish ? 'Yeniden dene' : 'Retry'),
          ),
        ] else ...[
          Text(widget.turkish ? 'Jellyfin bağlantısı' : 'Jellyfin connection'),
          const SizedBox(height: 8),
          CupertinoButton(
            key: const ValueKey('live-tv-source-service'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
              context,
            ),
            onPressed: widget.busy
                ? null
                : () =>
                      setState(() => _showServicePicker = !_showServicePicker),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${selected!.name} · ${selected.version}',
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                  ),
                ),
                const Icon(CupertinoIcons.chevron_up_chevron_down, size: 18),
              ],
            ),
          ),
          if (_showServicePicker) ...[
            const SizedBox(height: 8),
            Container(
              key: const ValueKey('live-tv-source-service-picker'),
              decoration: BoxDecoration(
                border: Border.all(color: CupertinoColors.separator),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  for (final option in widget.options)
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      onPressed: () => setState(() {
                        _serviceId = option.serviceId;
                        _showServicePicker = false;
                      }),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${option.name} · ${option.version}',
                              textAlign: TextAlign.left,
                            ),
                          ),
                          if (option.serviceId == selectedId)
                            const Icon(CupertinoIcons.check_mark, size: 18),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
          Text(widget.turkish ? 'Kaynak türü' : 'Source type'),
          const SizedBox(height: 8),
          IgnorePointer(
            ignoring: widget.busy,
            child: CupertinoSlidingSegmentedControl<String>(
              key: const ValueKey('live-tv-source-kind'),
              groupValue: _kind,
              children: {
                'iptv': Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('IPTV'),
                ),
                'tuner': Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(widget.turkish ? 'Tuner' : 'Tuner'),
                ),
              },
              onValueChanged: (value) {
                if (value != null) setState(() => _kind = value);
              },
            ),
          ),
          const SizedBox(height: 18),
          CupertinoTextField(
            key: const ValueKey('live-tv-source-time-zone'),
            controller: _timeZone,
            enabled: !widget.busy,
            placeholder: 'Europe/Istanbul',
            autocorrect: false,
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: 8),
          Text(
            widget.turkish
                ? 'IANA saat dilimi (ör. Europe/Istanbul)'
                : 'IANA time zone (for example Europe/Istanbul)',
            style: const TextStyle(
              fontSize: 13,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 18),
          Text(widget.turkish ? 'Kayıt kotası' : 'Recording quota'),
          const SizedBox(height: 8),
          IgnorePointer(
            ignoring: widget.busy,
            child: CupertinoSlidingSegmentedControl<int>(
              key: const ValueKey('live-tv-source-quota'),
              groupValue: _quota,
              children: const {
                10737418240: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('10 GiB'),
                ),
                53687091200: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('50 GiB'),
                ),
                107374182400: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('100 GiB'),
                ),
              },
              onValueChanged: (value) {
                if (value != null) setState(() => _quota = value);
              },
            ),
          ),
          const SizedBox(height: 22),
          CupertinoButton.filled(
            key: const ValueKey('live-tv-source-save'),
            onPressed: widget.busy
                ? null
                : () => widget.onConfigure(
                    selected,
                    _kind,
                    _timeZone.text.trim(),
                    _quota,
                  ),
            child: widget.busy
                ? const CupertinoActivityIndicator()
                : Text(widget.turkish ? 'Kaynağı bağla' : 'Connect source'),
          ),
        ],
      ],
    );
  }
}

final class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.busy,
    required this.message,
    required this.onRetry,
    required this.retryLabel,
  });
  final bool busy;
  final String message;
  final VoidCallback onRetry;
  final String retryLabel;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const CupertinoActivityIndicator(),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          if (!busy)
            CupertinoButton(onPressed: onRetry, child: Text(retryLabel)),
        ],
      ),
    ),
  );
}

final class _SourceSummary extends StatelessWidget {
  const _SourceSummary({required this.snapshot, required this.turkish});
  final ServerLiveTvSnapshot snapshot;
  final bool turkish;
  @override
  Widget build(BuildContext context) {
    final used = snapshot.usedBytes == null
        ? (turkish ? 'bilinmiyor' : 'unknown')
        : (snapshot.usedBytes! / 1073741824).toStringAsFixed(1);
    final quota = (snapshot.quotaBytes / 1073741824).toStringAsFixed(1);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            turkish ? 'Jellyfin Canlı TV' : 'Jellyfin Live TV',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '${snapshot.providerKind.toUpperCase()} · ${snapshot.timeZone.name} · ${snapshot.parallelTuners} ${turkish ? 'tuner' : 'tuners'}',
          ),
          const SizedBox(height: 4),
          Text(
            turkish
                ? 'Depolama: $used / $quota GiB'
                : 'Storage: $used / $quota GiB',
          ),
        ],
      ),
    );
  }
}

final class _ProgrammeCard extends StatelessWidget {
  const _ProgrammeCard({
    required this.programme,
    required this.snapshot,
    required this.turkish,
    required this.busy,
    required this.onSchedule,
  });
  final ServerLiveTvProgramme programme;
  final ServerLiveTvSnapshot snapshot;
  final bool turkish, busy;
  final VoidCallback? onSchedule;
  @override
  Widget build(BuildContext context) {
    final start = snapshot.timeZone.local(programme.startsAt);
    final end = snapshot.timeZone.local(programme.endsAt);
    final recorded = snapshot.recordingFor(programme.id) != null;
    final ended = !programme.endsAt.isAfter(DateTime.now().toUtc());
    return CupertinoListTile(
      title: Text(programme.title),
      subtitle: Text(
        '${programme.channelName} · ${DateFormat('dd MMM HH:mm').format(start)}–${DateFormat('HH:mm').format(end)} ${snapshot.timeZone.name}',
      ),
      trailing: recorded
          ? const Icon(CupertinoIcons.check_mark_circled_solid)
          : ended
          ? Text(turkish ? 'Bitti' : 'Ended')
          : CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: busy ? null : onSchedule,
              child: Text(turkish ? 'Kaydet' : 'Record'),
            ),
    );
  }
}

final class _RecordingCard extends StatelessWidget {
  const _RecordingCard({
    required this.recording,
    required this.snapshot,
    required this.turkish,
    required this.busy,
    this.onCancel,
    this.onRestart,
  });
  final ServerLiveTvRecording recording;
  final ServerLiveTvSnapshot snapshot;
  final bool turkish, busy;
  final VoidCallback? onCancel, onRestart;
  @override
  Widget build(BuildContext context) {
    final time = DateFormat('dd MMM HH:mm')
        .format(snapshot.timeZone.local(recording.startsAt));
    return CupertinoListTile(
      title: Text(recording.title),
      subtitle: Text(
        '${recording.channelName} · $time · ${recording.state.name}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onRestart != null)
            CupertinoButton(
              padding: const EdgeInsets.all(4),
              onPressed: busy ? null : onRestart,
              child: const Icon(CupertinoIcons.restart),
            ),
          if (onCancel != null)
            CupertinoButton(
              padding: const EdgeInsets.all(4),
              onPressed: busy ? null : onCancel,
              child: const Icon(CupertinoIcons.xmark_circle),
            ),
        ],
      ),
    );
  }
}
