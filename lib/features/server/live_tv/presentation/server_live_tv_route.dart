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
                ? _EmptyState(
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
    final used = (snapshot.usedBytes / 1073741824).toStringAsFixed(1);
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
            snapshot.providerId,
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
