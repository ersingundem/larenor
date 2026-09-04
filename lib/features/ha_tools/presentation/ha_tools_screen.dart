import 'dart:convert';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../ha_client/data/ha_api_exception.dart';
import '../../ha_client/data/ws_client.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../settings/presentation/panes/settings_nav_row.dart';
import '../domain/ha_action.dart';
import 'ha_tool_widgets.dart';

enum HaTool {
  server,
  history,
  logbook,
  calendars,
  templates,
  logs,
  checkConfig,
  events,
  api,
}

String haToolTitle(HaTool tool, AppLocalizations l10n) => switch (tool) {
  HaTool.server => l10n.haServerInfo,
  HaTool.history => l10n.haHistory,
  HaTool.logbook => l10n.haLogbook,
  HaTool.calendars => l10n.haCalendars,
  HaTool.templates => l10n.haTemplates,
  HaTool.logs => l10n.haLogs,
  HaTool.checkConfig => l10n.haCheckConfig,
  HaTool.events => l10n.haEvents,
  HaTool.api => l10n.haApiConsole,
};

class HaToolsScreen extends StatelessWidget {
  const HaToolsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SettingsPaneScaffold(
      title: l10n.haTools,
      children: [
        CupertinoListSection.insetGrouped(
          children: [
            for (final tool in HaTool.values)
              SettingsNavRow(
                icon: switch (tool) {
                  HaTool.history => CupertinoIcons.chart_bar,
                  HaTool.calendars => CupertinoIcons.calendar,
                  HaTool.events => CupertinoIcons.waveform,
                  _ => CupertinoIcons.chevron_left_slash_chevron_right,
                },
                color: CupertinoColors.systemBlue,
                title: haToolTitle(tool, l10n),
                builder: (_) => HaToolScreen(tool: tool),
              ),
          ],
        ),
      ],
    );
  }
}

class HaToolScreen extends ConsumerStatefulWidget {
  const HaToolScreen({super.key, required this.tool});
  final HaTool tool;
  @override
  ConsumerState<HaToolScreen> createState() => _HaToolScreenState();
}

class _HaToolScreenState extends ConsumerState<HaToolScreen> {
  final _entity = TextEditingController();
  final _start = TextEditingController(
    text: DateTime.now()
        .subtract(const Duration(hours: 24))
        .toUtc()
        .toIso8601String(),
  );
  final _end = TextEditingController(
    text: DateTime.now().toUtc().toIso8601String(),
  );
  final _template = TextEditingController(text: '{{ now() }}');
  final _endpoint = TextEditingController(text: '/api/config');
  final _body = TextEditingController(text: '{}');
  String _protocol = 'REST';
  String _method = 'GET';
  Object? _result;
  bool _error = false;
  bool _busy = false;
  bool _live = false;
  HaSubscription? _subscription;
  StreamSubscription<dynamic>? _listener;
  final _messages = <dynamic>[];
  final _eventType = TextEditingController(text: 'state_changed');

  Future<void> _stopStream() async {
    final subscription = _subscription;
    _subscription = null;
    final listener = _listener;
    _listener = null;
    await listener?.cancel();
    try {
      await subscription?.cancel();
    } catch (_) {
      /* Already disconnected. */
    }
  }

  Future<void> _startStream(Map<String, dynamic> command) async {
    final ws = ref.read(haWebSocketClientProvider);
    if (ws == null) {
      throw StateError(AppLocalizations.of(context).haDisconnected);
    }
    final subscription = await ws.subscribeCommand(command);
    if (!mounted) {
      await subscription.cancel();
      return;
    }
    _subscription = subscription;
    _messages.clear();
    _listener = subscription.events.listen(
      (event) {
        if (!mounted) return;
        setState(() {
          _messages.insert(0, event);
          if (_messages.length > 50) _messages.removeLast();
          _result = [..._messages];
        });
      },
      onError: (Object error) {
        if (mounted) {
          setState(() {
            _error = true;
            _result = '$error';
          });
        }
      },
      onDone: () {
        if (mounted) setState(() => _subscription = null);
      },
    );
  }

  @override
  void dispose() {
    unawaited(_stopStream());
    for (final c in [
      _entity,
      _start,
      _end,
      _template,
      _endpoint,
      _body,
      _eventType,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tool = widget.tool;
    return ServiceRootScaffold(
      title: haToolTitle(tool, l10n),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if ({
                  HaTool.history,
                  HaTool.logbook,
                  HaTool.calendars,
                }.contains(tool)) ...[
                  HaTextInput(
                    label: l10n.haEntityIds,
                    controller: _entity,
                    readOnly: _busy,
                  ),
                  HaTextInput(
                    label: l10n.haStart,
                    controller: _start,
                    readOnly: _busy,
                  ),
                  HaTextInput(
                    label: l10n.haEnd,
                    controller: _end,
                    readOnly: _busy,
                  ),
                ],
                if (tool == HaTool.events ||
                    (tool == HaTool.api && _protocol == 'WebSocket')) ...[
                  CupertinoListTile(
                    title: Text(l10n.haLive),
                    trailing: CupertinoSwitch(
                      value: _live,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _live = value),
                    ),
                  ),
                  if (tool == HaTool.events && _live)
                    HaTextInput(
                      label: l10n.haEventType,
                      controller: _eventType,
                    ),
                ],
                if (tool == HaTool.templates)
                  HaTextInput(
                    label: l10n.haTemplate,
                    controller: _template,
                    lines: 6,
                    readOnly: _busy,
                  ),
                if (tool == HaTool.api) ...[
                  HaHint(l10n.haApiHint),
                  CupertinoSlidingSegmentedControl<String>(
                    groupValue: _protocol,
                    children: const {
                      'REST': Text('REST'),
                      'WebSocket': Text('WebSocket'),
                    },
                    onValueChanged: (v) {
                      if (_busy) return;
                      setState(() {
                        _protocol = v!;
                        _body.text = _protocol == 'REST'
                            ? '{}'
                            : '{"type":"get_config"}';
                      });
                    },
                  ),
                  const SizedBox(height: 20),
                  if (_protocol == 'REST') ...[
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final method in [
                          'GET',
                          'POST',
                          'PUT',
                          'PATCH',
                          'DELETE',
                        ])
                          CupertinoButton(
                            sizeStyle: CupertinoButtonSize.small,
                            color: _method == method
                                ? CupertinoTheme.of(context).primaryColor
                                : null,
                            onPressed: _busy
                                ? null
                                : () => setState(() => _method = method),
                            child: Text(
                              method,
                              style: TextStyle(
                                color: _method == method
                                    ? CupertinoColors.white
                                    : null,
                              ),
                            ),
                          ),
                      ],
                    ),
                    HaTextInput(
                      label: l10n.haEndpoint,
                      controller: _endpoint,
                      readOnly: _busy,
                    ),
                  ],
                  if (_protocol == 'WebSocket' || _method != 'GET')
                    HaTextInput(
                      label: l10n.haBody,
                      controller: _body,
                      lines: 6,
                      readOnly: _busy,
                    ),
                  if (_protocol == 'REST') HaHint(l10n.haStateHint),
                ],
                if (_subscription != null)
                  CupertinoButton(
                    onPressed: () async {
                      await _stopStream();
                      if (mounted) setState(() {});
                    },
                    child: Text(l10n.haStopListening),
                  ),
                CupertinoButton.filled(
                  onPressed: _busy ? null : _run,
                  child: _busy
                      ? const CupertinoActivityIndicator()
                      : Text(tool == HaTool.api ? l10n.haRun : l10n.haRead),
                ),
              ],
            ),
          ),
        ),
        if (_result != null)
          SliverToBoxAdapter(
            child: HaResult(value: _result, isError: _error),
          ),
      ],
    );
  }

  Future<void> _run() async {
    final l10n = AppLocalizations.of(context);
    final client = ref.read(haRestClientProvider);
    if (client == null) {
      setState(() {
        _error = true;
        _result = l10n.haDisconnected;
      });
      return;
    }
    setState(() {
      _busy = true;
      _result = null;
      _error = false;
    });
    try {
      await _stopStream();
      if (!mounted) return;
      final ids = _entity.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      DateTime? start, end;
      if ({
        HaTool.history,
        HaTool.logbook,
        HaTool.calendars,
      }.contains(widget.tool)) {
        start = DateTime.tryParse(_start.text);
        end = DateTime.tryParse(_end.text);
        if (start == null || end == null || !end.isAfter(start)) {
          throw FormatException(l10n.haInvalidDate);
        }
      }
      Object? result;
      switch (widget.tool) {
        case HaTool.server:
          result = await client.getConfig();
        case HaTool.history:
          result = await client.getHistory(
            entityIds: ids,
            startTime: start,
            endTime: end,
            significantChangesOnly: false,
          );
        case HaTool.logbook:
          if (ids.length > 1) throw FormatException(l10n.adminInvalidValue);
          result = await client.getLogbook(
            entityId: ids.firstOrNull,
            startTime: start,
            endTime: end,
          );
        case HaTool.calendars:
          if (ids.length > 1) throw FormatException(l10n.adminInvalidValue);
          result = ids.isEmpty
              ? await client.getCalendars()
              : await client.getCalendarEvents(
                  ids.single,
                  start: start!,
                  end: end!,
                );
        case HaTool.templates:
          result = await client.renderTemplate(_template.text);
        case HaTool.logs:
          result = await client.getErrorLog();
        case HaTool.checkConfig:
          final check = await client.checkConfig();
          result = check;
          if (check['result'] == 'invalid') _error = true;
        case HaTool.events:
          if (_live) {
            await _startStream({
              'type': 'subscribe_events',
              if (_eventType.text.trim().isNotEmpty)
                'event_type': _eventType.text.trim(),
            });
            result = _messages.isEmpty ? l10n.haListening : [..._messages];
          } else {
            result = await client.getEvents();
          }
        case HaTool.api:
          final body = _protocol == 'REST' && _method == 'GET'
              ? <String, dynamic>{}
              : parseJsonObject(_body.text);
          if (_protocol == 'REST') {
            if (_method != 'GET' &&
                !await confirmHaAction(
                  context,
                  '$_method ${_endpoint.text}\n${jsonEncode(body)}',
                )) {
              return;
            }
            result = await client.requestText(
              _method,
              _endpoint.text.trim(),
              body: _method == 'GET' ? null : body,
            );
            try {
              result = jsonDecode(result as String);
            } on FormatException {
              /* Text endpoints are valid too. */
            }
          } else {
            if (!await confirmHaAction(context, jsonEncode(body))) return;
            final ws = ref.read(haWebSocketClientProvider);
            if (ws == null) throw StateError(l10n.haDisconnected);
            if (_live) {
              await _startStream(body);
              result = _messages.isEmpty ? l10n.haListening : [..._messages];
            } else {
              result = await ws.sendCommand(body);
            }
          }
      }
      if (mounted) setState(() => _result = result ?? l10n.haSuccess);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = true;
          _result = error is HaApiException && error.statusCode == 404
              ? l10n.haEndpointUnavailable
              : '$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
