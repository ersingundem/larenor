import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/utils/foreground_poller.dart';
import '../data/models/proxmox_task.dart';
import '../data/proxmox_client.dart';
import '../providers/proxmox_providers.dart';
import 'proxmox_session_guard.dart';

class ProxmoxTasksScreen extends ConsumerStatefulWidget {
  const ProxmoxTasksScreen({
    super.key,
    required this.nodeName,
    this.sourceCurrent,
  });

  final String nodeName;
  final bool Function()? sourceCurrent;

  @override
  ConsumerState<ProxmoxTasksScreen> createState() => _ProxmoxTasksScreenState();
}

class _ProxmoxTasksScreenState extends ProxmoxSessionState<ProxmoxTasksScreen> {
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent?.call() ?? true;

  late final ForegroundPoller _poller;
  bool _visible = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    if (_visible) {
      _poller.start(immediately: false);
    } else {
      _poller.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    _poller = ForegroundPoller(
      interval: const Duration(seconds: 10),
      poll: () async {
        if (!_visible ||
            !sessionAvailable ||
            ModalRoute.of(context)?.isCurrent == false) {
          return;
        }
        final provider = proxmoxTasksProvider(widget.nodeName);
        if (!ref.exists(provider)) return;
        // Await the current read rather than invalidating it every interval.
        if (!ref.read(provider).isLoading) ref.invalidate(provider);
        await ref.read(provider.future);
      },
    )..start(immediately: false);
  }

  void _refresh() {
    if (_visible &&
        sessionAvailable &&
        ModalRoute.of(context)?.isCurrent != false) {
      _poller.refresh();
    }
  }

  @override
  void dispose() {
    _poller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchProxmoxSession();
    final l10n = AppLocalizations.of(context);
    if (!_visible || !sessionAvailable) {
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(l10n.proxmoxTasksTitle),
        ),
        child: SafeArea(child: Center(child: Text(l10n.proxmoxSessionExpired))),
      );
    }
    final generation = sessionGeneration;
    final tasks = ref.watch(proxmoxTasksProvider(widget.nodeName));
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.proxmoxTasksTitle),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _refresh,
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: tasks.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.commonError),
            ),
          ),
          data: (items) => items.isEmpty
              ? Center(child: Text(l10n.proxmoxNoTasks))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final task = items[index];
                    return CupertinoListTile(
                      leading: Icon(
                        task.isRunning
                            ? CupertinoIcons.clock
                            : task.isSuccess
                            ? CupertinoIcons.checkmark_circle_fill
                            : CupertinoIcons.exclamationmark_circle_fill,
                        color: task.isRunning
                            ? CupertinoColors.systemOrange
                            : task.isSuccess
                            ? CupertinoColors.systemGreen
                            : CupertinoColors.systemRed,
                      ),
                      title: Text(
                        '${task.type}${task.resourceId?.isNotEmpty == true ? ' · ${task.resourceId}' : ''}',
                      ),
                      subtitle: Text(
                        task.isRunning
                            ? l10n.proxmoxTaskRunning
                            : task.isSuccess
                            ? l10n.proxmoxTaskSucceeded
                            : l10n.commonError,
                      ),
                      additionalInfo: _taskTime(task.startTimeSeconds) == null
                          ? null
                          : Text(_taskTime(task.startTimeSeconds)!),
                      trailing: const CupertinoListTileChevron(),
                      onTap: () {
                        if (!mounted ||
                            !sessionAvailable ||
                            generation != sessionGeneration ||
                            ModalRoute.of(context)?.isCurrent == false) {
                          return;
                        }
                        final current = ref.read(
                          proxmoxTasksProvider(widget.nodeName),
                        );
                        if (current.isLoading ||
                            current.hasError ||
                            current.value?.any(
                                  (value) => value.upid == task.upid,
                                ) !=
                                true) {
                          return;
                        }
                        final source = captureProxmoxRouteSource(ref);
                        if (source == null) return;
                        final nodeName = widget.nodeName;
                        Navigator.of(context).push(
                          CupertinoPageRoute<void>(
                            builder: (_) => _TaskLogScreen(
                              nodeName: nodeName,
                              task: task,
                              sourceCurrent: source,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ),
    );
  }
}

String? _taskTime(int? seconds) {
  if (seconds == null || seconds < 0 || seconds > 8640000000000) return null;
  try {
    final value = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
    String part(int number) => '$number'.padLeft(2, '0');
    return '${part(value.month)}-${part(value.day)} ${part(value.hour)}:${part(value.minute)}';
  } on ArgumentError {
    return null;
  }
}

class _TaskLogScreen extends ConsumerStatefulWidget {
  const _TaskLogScreen({
    required this.nodeName,
    required this.task,
    this.sourceCurrent,
  });

  final String nodeName;
  final ProxmoxTask task;
  final bool Function()? sourceCurrent;

  @override
  ConsumerState<_TaskLogScreen> createState() => _TaskLogScreenState();
}

class _TaskLogScreenState extends ProxmoxSessionState<_TaskLogScreen> {
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent?.call() ?? true;

  List<String>? _lines;
  ProxmoxTaskPoll? _status;
  String? _error;
  bool _loading = false;
  late final ForegroundPoller _poller;
  bool _visible = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (_visible == visible) return;
    _visible = visible;
    if (!visible) {
      sessionGeneration++;
      onSessionInvalidated();
      _poller.stop();
    } else {
      _poller.start(immediately: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _poller = ForegroundPoller(
      interval: const Duration(seconds: 3),
      poll: _fetch,
    );
  }

  @override
  void onSessionInvalidated() {
    _lines = null;
    _status = null;
    _error = null;
    _loading = false;
  }

  @override
  void onSessionResumed() => _refresh();

  void _refresh() {
    if (!_visible ||
        !sessionAvailable ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    _poller.start(immediately: false);
    _poller.refresh();
  }

  Future<void> _fetch() async {
    if (!_visible ||
        !sessionAvailable ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final generation = sessionGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lease = await readSessionClient();
      if (lease == null || !_poller.isActive || !isSessionCurrent(lease)) {
        return;
      }
      final status = await lease.client.getTaskStatus(
        widget.nodeName,
        widget.task.upid,
      );
      if (!_poller.isActive || !isSessionCurrent(lease)) return;
      final lines = await lease.client.getTaskLog(
        widget.nodeName,
        widget.task.upid,
      );
      if (!_poller.isActive || !isSessionCurrent(lease)) return;
      setState(() {
        _lines = lines;
        _status = status;
      });
      if (!status.isRunning) _poller.stop();
    } catch (error) {
      if (mounted && sessionAvailable && generation == sessionGeneration) {
        setState(() => _error = AppLocalizations.of(context).commonError);
      }
    } finally {
      if (mounted && generation == sessionGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _poller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchProxmoxSession();
    if (_visible && sessionAvailable) ref.watch(proxmoxClientProvider);
    final l10n = AppLocalizations.of(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.proxmoxTaskLogTitle),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _loading || !sessionAvailable ? null : _refresh,
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: !sessionAvailable
            ? Center(child: Text(l10n.proxmoxSessionExpired))
            : _lines == null && _loading
            ? const Center(child: CupertinoActivityIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    '${widget.task.type}${widget.task.resourceId?.isNotEmpty == true ? ' · ${widget.task.resourceId}' : ''}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_status != null)
                    Text(
                      _status!.isRunning
                          ? l10n.proxmoxTaskRunning
                          : _status!.isSuccess
                          ? l10n.proxmoxTaskSucceeded
                          : l10n.commonError,
                    ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: const TextStyle(color: CupertinoColors.systemRed),
                    ),
                  const SizedBox(height: 20),
                  SelectableText(
                    _lines?.isNotEmpty == true
                        ? _lines!.join('\n')
                        : l10n.proxmoxTaskNoLog,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
