import 'dart:convert';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/spacing.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../auth/providers/auth_providers.dart';
import '../../dashboard/presentation/dashboard_edit_guard.dart';
import '../../ha_client/data/ha_api_exception.dart';
import '../../ha_client/data/rest_client.dart';
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

class _HaToolScreenState extends DashboardEditState<HaToolScreen> {
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
  bool _expired = false;
  Route<bool>? _dialog;
  bool? _wasVisible, _wasCurrent;
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if ((_wasVisible == true && !visible) ||
        (_wasCurrent == true && !current && _dialog == null)) {
      interactionGeneration++;
      invalidateDashboardInteraction();
    }
    _wasVisible = visible;
    _wasCurrent = current;
  }

  @override
  void invalidateDashboardInteraction() {
    _expired = true;
    _busy = false;
    _result = null;
    unawaited(_stopStream());
    final route = _dialog;
    _dialog = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  bool _valid(int generation) => !_expired && interactionCurrent(generation);

  bool _restCurrent(int generation, HaRestClient client) =>
      _valid(generation) && identical(ref.read(haRestClientProvider), client);

  bool _wsCurrent(int generation, HaWebSocketClient client) =>
      _valid(generation) &&
      identical(ref.read(haWebSocketClientProvider), client);

  Future<void> _startStream(
    Map<String, dynamic> command,
    int generation,
    HaWebSocketClient? ws,
  ) async {
    if (ws == null) {
      throw StateError(AppLocalizations.of(context).haDisconnected);
    }
    final subscription = await ws.subscribeCommand(command);
    if (!_wsCurrent(generation, ws)) {
      await subscription.cancel();
      return;
    }
    _subscription = subscription;
    _messages.clear();
    _listener = subscription.events.listen(
      (event) {
        if (!_wsCurrent(generation, ws)) {
          unawaited(_stopStream());
          return;
        }
        setState(() {
          _messages.insert(0, event);
          if (_messages.length > 50) _messages.removeLast();
          _result = [..._messages];
        });
      },
      onError: (Object _) {
        if (_wsCurrent(generation, ws)) {
          setState(() {
            _error = true;
            _result = AppLocalizations.of(context).actionFailed;
          });
        }
      },
      onDone: () {
        if (_wsCurrent(generation, ws)) {
          setState(() => _subscription = null);
        }
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
    // This is an operational HA surface, so account changes are part of its
    // authority rather than an optional dashboard preview dependency.
    final authority = ref.watch(connectionConfigProvider);
    if (authority.hasValue) watchDashboardAccount();
    ref.listen(haRestClientProvider, (previous, next) {
      if (previous != null && !identical(previous, next)) {
        setState(() {
          interactionGeneration++;
          invalidateDashboardInteraction();
        });
      }
    });
    ref.listen(haWebSocketClientProvider, (previous, next) {
      if (previous != null && !identical(previous, next)) {
        setState(() {
          interactionGeneration++;
          invalidateDashboardInteraction();
        });
      }
    });
    final l10n = AppLocalizations.of(context);
    final tool = widget.tool;
    final canInteract = _valid(interactionGeneration);
    return ServiceRootScaffold(
      title: haToolTitle(tool, l10n),
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              container: true,
              header: true,
              child: Text(
                l10n.haRequest,
                key: const ValueKey('ha-request-heading'),
              ),
            ),
            children: [
              Padding(
                padding: Insets.tile,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_expired) HaHint(l10n.dashboardWidgetPickerExpired),
                    if ({
                      HaTool.history,
                      HaTool.logbook,
                      HaTool.calendars,
                    }.contains(tool)) ...[
                      HaTextInput(
                        label: l10n.haEntityIds,
                        controller: _entity,
                        readOnly: _busy || !canInteract,
                      ),
                      HaTextInput(
                        label: l10n.haStart,
                        controller: _start,
                        readOnly: _busy || !canInteract,
                      ),
                      HaTextInput(
                        label: l10n.haEnd,
                        controller: _end,
                        readOnly: _busy || !canInteract,
                      ),
                    ],
                    if (tool == HaTool.events ||
                        (tool == HaTool.api && _protocol == 'WebSocket')) ...[
                      CupertinoListTile(
                        title: Text(l10n.haLive),
                        trailing: Semantics(
                          label: l10n.haLive,
                          button: true,
                          toggled: _live,
                          enabled: !_busy && canInteract,
                          child: ExcludeSemantics(
                            child: CupertinoButton(
                              key: const ValueKey('ha-live-toggle'),
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(60, 48),
                              onPressed: _busy || !canInteract
                                  ? null
                                  : () {
                                      final generation = interactionGeneration;
                                      if (!_valid(generation)) return;
                                      setState(() => _live = !_live);
                                    },
                              child: CupertinoSwitch(
                                value: _live,
                                onChanged: null,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (tool == HaTool.events && _live)
                        HaTextInput(
                          label: l10n.haEventType,
                          controller: _eventType,
                          readOnly: _busy || !canInteract,
                        ),
                    ],
                    if (tool == HaTool.templates)
                      HaTextInput(
                        label: l10n.haTemplate,
                        controller: _template,
                        lines: 6,
                        readOnly: _busy || !canInteract,
                      ),
                    if (tool == HaTool.api) ...[
                      HaHint(l10n.haApiHint),
                      ConstrainedBox(
                        key: const ValueKey('ha-protocol-control'),
                        constraints: const BoxConstraints(minHeight: 48),
                        child: CupertinoSlidingSegmentedControl<String>(
                          groupValue: _protocol,
                          children: const {
                            'REST': Text('REST'),
                            'WebSocket': Text('WebSocket'),
                          },
                          onValueChanged: (v) {
                            if (_busy || !canInteract) return;
                            setState(() {
                              _protocol = v!;
                              _body.text = _protocol == 'REST'
                                  ? '{}'
                                  : '{"type":"get_config"}';
                            });
                          },
                        ),
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
                                minimumSize: const Size(48, 48),
                                color: _method == method
                                    ? CupertinoTheme.of(context).primaryColor
                                    : null,
                                onPressed: _busy || !canInteract
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
                          readOnly: _busy || !canInteract,
                        ),
                      ],
                      if (_protocol == 'WebSocket' || _method != 'GET')
                        HaTextInput(
                          label: l10n.haBody,
                          controller: _body,
                          lines: 6,
                          readOnly: _busy || !canInteract,
                        ),
                      if (_protocol == 'REST') HaHint(l10n.haStateHint),
                    ],
                    if (_subscription != null)
                      CupertinoButton(
                        key: const ValueKey('ha-stop-listening'),
                        minimumSize: const Size(48, 48),
                        onPressed: !canInteract
                            ? null
                            : () async {
                                final generation = interactionGeneration;
                                if (!_valid(generation)) return;
                                await _stopStream();
                                if (_valid(generation)) setState(() {});
                              },
                        child: Text(l10n.haStopListening),
                      ),
                    CupertinoButton.filled(
                      key: const ValueKey('ha-primary-action'),
                      minimumSize: const Size(48, 48),
                      onPressed: _busy || !canInteract ? null : _run,
                      child: _busy
                          ? const CupertinoActivityIndicator()
                          : Text(tool == HaTool.api ? l10n.haRun : l10n.haRead),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_result != null)
          SliverToBoxAdapter(
            child: SettingsSection(
              children: [HaResult(value: _result, isError: _error)],
            ),
          ),
      ],
    );
  }

  Future<void> _run() async {
    final generation = interactionGeneration;
    if (!_valid(generation) || _busy) return;
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
      if (!_restCurrent(generation, client)) return;
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
            await _startStream(
              {
                'type': 'subscribe_events',
                if (_eventType.text.trim().isNotEmpty)
                  'event_type': _eventType.text.trim(),
              },
              generation,
              ref.read(haWebSocketClientProvider),
            );
            if (!_restCurrent(generation, client)) return;
            result = _messages.isEmpty ? l10n.haListening : [..._messages];
          } else {
            result = await client.getEvents();
          }
        case HaTool.api:
          final body = _protocol == 'REST' && _method == 'GET'
              ? <String, dynamic>{}
              : parseJsonObject(_body.text);
          if (!_restCurrent(generation, client) || !mounted) return;
          if (_protocol == 'REST') {
            if (_method != 'GET' &&
                !await confirmHaAction(
                  context,
                  '$_method ${_endpoint.text}\n${jsonEncode(body)}',
                  onRoute: (route) => _dialog = route,
                )) {
              return;
            }
            if (!_restCurrent(generation, client)) return;
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
            if (!await confirmHaAction(
              context,
              jsonEncode(body),
              onRoute: (route) => _dialog = route,
            )) {
              return;
            }
            if (!_restCurrent(generation, client)) return;
            final ws = ref.read(haWebSocketClientProvider);
            if (ws == null) {
              throw HaApiException(l10n.haDisconnected, code: 'not_connected');
            }
            if (_live) {
              await _startStream(body, generation, ws);
              if (!_wsCurrent(generation, ws)) return;
              result = _messages.isEmpty ? l10n.haListening : [..._messages];
            } else {
              result = await ws.sendCommand(body);
            }
          }
      }
      if (_restCurrent(generation, client)) {
        setState(() => _result = result ?? l10n.haSuccess);
      }
    } catch (error) {
      if (_restCurrent(generation, client)) {
        setState(() {
          _error = true;
          _result = _safeFailureLabel(l10n, error);
        });
      }
    } finally {
      if (_restCurrent(generation, client)) setState(() => _busy = false);
    }
  }
}

String _safeFailureLabel(AppLocalizations l10n, Object error) {
  if (error is HaApiException) {
    if (error.statusCode == 404) return l10n.haEndpointUnavailable;
    if (error.code == 'not_connected') return l10n.haDisconnected;
  }
  if (error is FormatException) {
    final message = error.message.toString();
    if (message == l10n.haInvalidDate || message == l10n.adminInvalidValue) {
      return message;
    }
    return l10n.adminInvalidValue;
  }
  return l10n.actionFailed;
}
