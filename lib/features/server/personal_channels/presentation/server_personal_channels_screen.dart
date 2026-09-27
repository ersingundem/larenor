import 'package:flutter/cupertino.dart';

import '../data/server_personal_channel_controller.dart';
import '../domain/server_personal_channel_models.dart';

typedef ServerPersonalChannelSourcePicker =
    Future<List<ServerPersonalChannelSource>?> Function(
      BuildContext context, {
      required int maximum,
    });

final class ServerPersonalChannelStrings {
  const ServerPersonalChannelStrings({
    required this.title,
    required this.empty,
    required this.create,
    required this.channelName,
    required this.loopSchedule,
    required this.guide,
    required this.live,
    required this.restart,
    required this.gapDeleted,
    required this.gapUnreachable,
    required this.reschedule,
    required this.cancelChannel,
    required this.cancel,
    required this.keep,
    required this.retry,
    required this.ok,
    required this.noAuthorizedSources,
  });

  final String title;
  final String empty;
  final String create;
  final String channelName;
  final String loopSchedule;
  final String guide;
  final String live;
  final String restart;
  final String gapDeleted;
  final String gapUnreachable;
  final String reschedule;
  final String cancelChannel;
  final String cancel;
  final String keep;
  final String retry;
  final String ok;
  final String noAuthorizedSources;
}

final class ServerPersonalChannelsScreen extends StatefulWidget {
  const ServerPersonalChannelsScreen({
    super.key,
    required this.controller,
    required this.strings,
    required this.pickSources,
    required this.onPlayback,
    required this.errorLabel,
  });

  final ServerPersonalChannelController controller;
  final ServerPersonalChannelStrings strings;
  final ServerPersonalChannelSourcePicker pickSources;
  final Future<void> Function(ServerPersonalPlaybackSource source) onPlayback;
  final String Function(String code) errorLabel;

  @override
  State<ServerPersonalChannelsScreen> createState() =>
      _ServerPersonalChannelsScreenState();
}

class _ServerPersonalChannelsScreenState
    extends State<ServerPersonalChannelsScreen> {
  int _generation = 0;

  bool _current(int generation) => mounted && generation == _generation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final generation = _generation;
      widget.controller.load(current: () => _current(generation));
    });
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    await widget.controller.load(current: () => _current(generation));
  }

  Future<void> _create() async {
    final sources = await widget.pickSources(context, maximum: 64);
    if (!mounted || sources == null) return;
    if (sources.isEmpty) {
      await _notice(widget.strings.noAuthorizedSources);
      return;
    }
    final name = await _askName();
    if (!mounted || name == null) return;
    final generation = ++_generation;
    await widget.controller.create(
      name: name,
      startsAt: DateTime.now().toUtc(),
      loop: true,
      sources: sources,
      current: () => _current(generation),
    );
  }

  Future<String?> _askName() async {
    final controller = TextEditingController();
    final result = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(widget.strings.channelName),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            maxLength: 80,
            autofocus: true,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.strings.cancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: Text(widget.strings.create),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _select(ServerPersonalChannel channel) async {
    final generation = ++_generation;
    await widget.controller.select(
      channel.id,
      current: () => _current(generation),
    );
  }

  Future<void> _play(
    ServerPersonalProgramme programme,
    ServerPersonalPlaybackMode mode,
  ) async {
    final generation = ++_generation;
    await widget.controller.resolve(
      programme: programme,
      mode: mode,
      current: () => _current(generation),
    );
    final playback = widget.controller.playback;
    if (_current(generation) && playback != null) {
      await widget.onPlayback(playback);
    }
  }

  Future<void> _reschedule(ServerPersonalProgramme programme) async {
    final sources = await widget.pickSources(context, maximum: 1);
    if (!mounted || sources == null || sources.isEmpty) return;
    final generation = ++_generation;
    await widget.controller.reschedule(
      programme: programme,
      replacement: sources.single,
      current: () => _current(generation),
    );
  }

  Future<void> _cancel() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(widget.strings.cancelChannel),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.strings.keep),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.strings.cancelChannel),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final generation = ++_generation;
    await widget.controller.cancel(current: () => _current(generation));
  }

  Future<void> _notice(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.strings.ok),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: Text(widget.strings.title),
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: widget.controller.busy ? null : _refresh,
        child: const Icon(CupertinoIcons.refresh),
      ),
    ),
    child: SafeArea(
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => _body(),
      ),
    ),
  );

  Widget _body() {
    final controller = widget.controller;
    if (controller.busy && controller.channels.isEmpty) {
      return const Center(child: CupertinoActivityIndicator());
    }
    return CustomScrollView(
      slivers: [
        if (controller.failure != null)
          SliverToBoxAdapter(
            child: _IssueCard(
              message: widget.errorLabel(controller.failure!),
              retry: widget.strings.retry,
              onRetry: _refresh,
            ),
          ),
        if (controller.channels.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyState(
              message: widget.strings.empty,
              action: widget.strings.create,
              busy: controller.busy,
              onCreate: _create,
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: CupertinoListSection.insetGrouped(
              children: [
                for (final channel in controller.channels)
                  CupertinoListTile.notched(
                    title: Text(channel.name),
                    subtitle: Text(
                      '${channel.programmes.length} · ${widget.strings.loopSchedule}',
                    ),
                    trailing: const CupertinoListTileChevron(),
                    onTap: controller.busy ? null : () => _select(channel),
                  ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: CupertinoButton.filled(
                onPressed: controller.busy ? null : _create,
                child: Text(widget.strings.create),
              ),
            ),
          ),
          if (controller.selected != null) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 6),
                child: Text(
                  '${widget.strings.guide} · ${controller.selected!.name}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            SliverList.builder(
              itemCount: controller.selected!.programmes.length,
              itemBuilder: (context, index) => _ProgrammeCard(
                programme: controller.selected!.programmes[index],
                strings: widget.strings,
                busy: controller.busy,
                onLive: _play,
                onReschedule: _reschedule,
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                child: CupertinoButton(
                  color: CupertinoColors.systemRed,
                  onPressed: controller.busy ? null : _cancel,
                  child: Text(widget.strings.cancelChannel),
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

final class _ProgrammeCard extends StatelessWidget {
  const _ProgrammeCard({
    required this.programme,
    required this.strings,
    required this.busy,
    required this.onLive,
    required this.onReschedule,
  });

  final ServerPersonalProgramme programme;
  final ServerPersonalChannelStrings strings;
  final bool busy;
  final Future<void> Function(
    ServerPersonalProgramme,
    ServerPersonalPlaybackMode,
  )
  onLive;
  final Future<void> Function(ServerPersonalProgramme) onReschedule;

  @override
  Widget build(BuildContext context) {
    final localStart = programme.startsAt.toLocal();
    final localEnd = programme.endsAt.toLocal();
    final time =
        '${_two(localStart.hour)}:${_two(localStart.minute)}–'
        '${_two(localEnd.hour)}:${_two(localEnd.minute)}';
    final gap = programme.state == ServerPersonalProgrammeState.gap;
    final now = DateTime.now().toUtc();
    final canWatchLive = programme.contains(now);
    final canRestart =
        !now.isBefore(programme.startsAt) &&
        now.difference(programme.startsAt) <= const Duration(days: 7);
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CupertinoDynamicColor.resolve(
          CupertinoColors.secondarySystemGroupedBackground,
          context,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            time,
            style: const TextStyle(color: CupertinoColors.secondaryLabel),
          ),
          const SizedBox(height: 4),
          Text(
            gap ? _gapLabel() : programme.title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          if (gap)
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: busy ? null : () => onReschedule(programme),
              child: Text(strings.reschedule),
            )
          else
            Wrap(
              spacing: 10,
              children: [
                if (canWatchLive)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: busy
                        ? null
                        : () => onLive(
                            programme,
                            ServerPersonalPlaybackMode.live,
                          ),
                    child: Text(strings.live),
                  ),
                if (canRestart)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: busy
                        ? null
                        : () => onLive(
                            programme,
                            ServerPersonalPlaybackMode.restart,
                          ),
                    child: Text(strings.restart),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  String _gapLabel() =>
      programme.reason == ServerPersonalProgrammeReason.deleted
      ? strings.gapDeleted
      : strings.gapUnreachable;

  static String _two(int value) => value.toString().padLeft(2, '0');
}

final class _IssueCard extends StatelessWidget {
  const _IssueCard({
    required this.message,
    required this.retry,
    required this.onRetry,
  });

  final String message, retry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      children: [
        Text(message),
        CupertinoButton(onPressed: onRetry, child: Text(retry)),
      ],
    ),
  );
}

final class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.message,
    required this.action,
    required this.busy,
    required this.onCreate,
  });

  final String message, action;
  final bool busy;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.tv, size: 44),
          const SizedBox(height: 14),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 18),
          CupertinoButton.filled(
            onPressed: busy ? null : onCreate,
            child: Text(busy ? '…' : action),
          ),
        ],
      ),
    ),
  );
}
