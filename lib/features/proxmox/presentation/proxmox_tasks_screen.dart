import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/proxmox_task.dart';
import '../data/proxmox_client.dart';
import '../providers/proxmox_providers.dart';

class ProxmoxTasksScreen extends ConsumerStatefulWidget {
  const ProxmoxTasksScreen({super.key, required this.nodeName});

  final String nodeName;

  @override
  ConsumerState<ProxmoxTasksScreen> createState() => _ProxmoxTasksScreenState();
}

class _ProxmoxTasksScreenState extends ConsumerState<ProxmoxTasksScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  void _refresh() => ref.invalidate(proxmoxTasksProvider(widget.nodeName));

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.adminLoadError(error.toString())),
            ),
          ),
          data: (items) => items.isEmpty
              ? Center(child: Text(l10n.proxmoxNoTasks))
              : ListView(
                  children: [
                    CupertinoListSection.insetGrouped(
                      children: [
                        for (final task in items)
                          CupertinoListTile(
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
                                  : task.status ?? '',
                            ),
                            additionalInfo: task.startTimeSeconds == null
                                ? null
                                : Text(
                                    DateTime.fromMillisecondsSinceEpoch(
                                      task.startTimeSeconds! * 1000,
                                    ).toLocal().toString().substring(5, 16),
                                  ),
                            trailing: const CupertinoListTileChevron(),
                            onTap: () => Navigator.of(context).push(
                              CupertinoPageRoute<void>(
                                builder: (_) => _TaskLogScreen(
                                  nodeName: widget.nodeName,
                                  task: task,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _TaskLogScreen extends ConsumerStatefulWidget {
  const _TaskLogScreen({required this.nodeName, required this.task});

  final String nodeName;
  final ProxmoxTask task;

  @override
  ConsumerState<_TaskLogScreen> createState() => _TaskLogScreenState();
}

class _TaskLogScreenState extends ConsumerState<_TaskLogScreen> {
  List<String>? _lines;
  ProxmoxTaskPoll? _status;
  String? _error;
  bool _loading = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _timer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = await ref.read(proxmoxClientProvider.future);
      if (client == null) return;
      final status = await client.getTaskStatus(
        widget.nodeName,
        widget.task.upid,
      );
      final lines = await client.getTaskLog(widget.nodeName, widget.task.upid);
      if (!mounted) return;
      setState(() {
        _lines = lines;
        _status = status;
      });
      if (status.isRunning) {
        _timer = Timer(const Duration(seconds: 3), _refresh);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(proxmoxClientProvider);
    final l10n = AppLocalizations.of(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.proxmoxTaskLogTitle),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _loading ? null : _refresh,
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: _lines == null && _loading
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
                          : _status!.exitStatus ?? l10n.commonError,
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
