import 'dart:async';

import 'package:http/http.dart' as http;

import '../../../shared/network/server_bound_client.dart';

import 'proxmox_api_exception.dart';
import 'proxmox_config.dart';
import 'proxmox_http_client.dart';
import 'proxmox_transport.dart';
import '../../health/data/health_monitor.dart';
import '../../health/data/integration_health.dart';
import 'models/proxmox_values.dart';
import 'models/proxmox_backup.dart';
import 'models/proxmox_guest.dart';
import 'models/proxmox_node.dart';
import 'models/proxmox_storage.dart';
import 'models/proxmox_task.dart';

/// Result of a `vncproxy`/`termproxy` call — everything needed to open the
/// console websocket.
class ProxmoxConsoleTicket {
  const ProxmoxConsoleTicket({required this.ticket, required this.port});

  final String ticket;
  final int port;
}

/// A snapshot of a task's completion state, from `/tasks/{upid}/status` —
/// a different response shape than the task-log list entries in
/// [ProxmoxTask], so it gets its own small value type instead of reusing it.
class ProxmoxTaskPoll {
  const ProxmoxTaskPoll({required this.isRunning, this.exitStatus});

  final bool isRunning;
  final String? exitStatus;

  bool get isSuccess => !isRunning && exitStatus == 'OK';
}

/// Hand-rolled client over the Proxmox VE REST API (`/api2/json/*`).
///
/// Uses the existing ticket/cookie and CSRF authentication flow. Partial MFA
/// challenge responses are rejected until the extra authentication is completed;
/// they must never be stored as an established session.
class ProxmoxClient {
  ProxmoxClient({
    required this.config,
    http.Client? httpClient,
    DateTime Function()? now,
    this.healthSession,
    Duration requestTimeout = const Duration(seconds: 15),
    Duration cloneTimeout = const Duration(seconds: 30),
  }) : _now = now ?? DateTime.now {
    _client = ProxmoxTransport(
      inner: ServerBoundClient(
        baseUrl: config.baseUrl,
        inner:
            httpClient ??
            buildProxmoxHttpClient(
              allowSelfSigned: config.allowSelfSigned,
              server: Uri.parse(config.baseUrl),
            ),
      ),
      onContact: () {
        if (!_disposed) healthSession?.contact();
      },
      requestTimeout: requestTimeout,
      cloneTimeout: cloneTimeout,
    );
  }
  final ProxmoxConfig config;
  late final ProxmoxTransport _client;
  final HealthSession? healthSession;
  final DateTime Function() _now;
  String? _ticket, _csrfToken;
  DateTime? _authenticatedAt;
  Future<void>? _loginFuture;
  final _pendingMutations = <String>{};
  bool _disposed = false;
  int _sessionGeneration = 0;
  bool get isAuthenticated =>
      !_disposed && _ticket != null && _csrfToken != null;
  void _checkActive() {
    if (_disposed) {
      throw ProxmoxApiException(
        'Connection is no longer active.',
        failure: ProxmoxFailure.inactive,
      );
    }
  }

  Future<void> login() {
    _checkActive();
    if (_loginFuture case final pending?) return pending;
    late final Future<void> pending;
    pending = _login().whenComplete(() {
      if (identical(_loginFuture, pending)) _loginFuture = null;
    });
    _loginFuture = pending;
    return pending;
  }

  Future<void> ensureAuthenticated() async {
    _checkActive();
    if (_ticket == null ||
        _authenticatedAt == null ||
        _now().isBefore(_authenticatedAt!) ||
        _now().difference(_authenticatedAt!) >= const Duration(minutes: 110)) {
      await login();
    }
    _checkActive();
  }

  Future<http.Response> _authenticatedRequest(
    Future<http.Response> Function() send, {
    bool readOnly = true,
    String? target,
  }) async {
    _checkActive();
    if (!readOnly && (target == null || !_pendingMutations.add(target))) {
      throw ProxmoxApiException(
        'An action is already pending for this target.',
        failure: ProxmoxFailure.actionPending,
      );
    }
    try {
      await ensureAuthenticated();
      final generation = _sessionGeneration;
      var response = await send();
      _checkActive();
      if (readOnly && response.statusCode == 401) {
        if (generation == _sessionGeneration) await login();
        _checkActive();
        response = await send();
      }
      _checkActive();
      _checkOk(response);
      return response;
    } on ProxmoxApiException catch (error) {
      if (!_disposed) _report(error.failure);
      rethrow;
    } finally {
      if (!readOnly) _pendingMutations.remove(target);
    }
  }

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('${config.baseUrl}/api2/json$path');
    if (query == null) return uri;
    return uri.replace(
      queryParameters: query.map((key, value) => MapEntry(key, '$value')),
    );
  }

  Map<String, String> get _headers {
    final ticket = _ticket;
    return {if (ticket != null) 'Cookie': 'PVEAuthCookie=$ticket'};
  }

  Map<String, String> get _mutatingHeaders {
    final csrf = _csrfToken;
    return {..._headers, 'CSRFPreventionToken': ?csrf};
  }

  Future<void> _login() async {
    _checkActive();
    healthSession?.connecting();
    _ticket = null;
    _csrfToken = null;
    _authenticatedAt = null;
    try {
      final response = await _client.post(
        _uri('/access/ticket'),
        body: {'username': config.userWithRealm, 'password': config.password},
      );
      _checkActive();
      final data = _objectData(response);
      final ticket = data['ticket'];
      final csrf = data['CSRFPreventionToken'];
      if (data['NeedTFA'] == 1 ||
          data['NeedTFA'] == true ||
          (ticket is String && ticket.contains('!tfa!'))) {
        throw ProxmoxApiException(
          'Additional authentication is required.',
          failure: ProxmoxFailure.authentication,
        );
      }
      if (!_safeSessionValue(ticket) || !_safeSessionValue(csrf)) {
        throw _invalid();
      }
      _ticket = ticket as String;
      _csrfToken = csrf as String;
      _authenticatedAt = _now();
      _sessionGeneration++;
      // Auth is contact evidence only. A parsed resource read proves access.
    } on ProxmoxApiException catch (error) {
      if (!_disposed) _report(error.failure);
      rethrow;
    }
  }

  bool _safeSessionValue(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 16384 &&
      !value.contains(RegExp(r'[\x00-\x20\x7f;,]'));

  Future<List<ProxmoxNode>> getNodes() async {
    final response = await _authenticatedRequest(
      () => _client.get(_uri('/nodes'), headers: _headers),
    );
    return _readList(response, ProxmoxNode.fromJson);
  }

  Future<List<ProxmoxGuest>> getGuests(String node) async {
    final results = await Future.wait([
      _getGuestsOfType(node, ProxmoxGuestType.qemu),
      _getGuestsOfType(node, ProxmoxGuestType.lxc),
    ]);
    _checkActive();
    final guests = [...results[0], ...results[1]];
    if (guests.map((guest) => guest.vmid).toSet().length != guests.length) {
      _report(ProxmoxFailure.invalidResponse);
      throw _invalid();
    }
    healthSession?.readSucceeded();
    return guests..sort((a, b) => a.vmid.compareTo(b.vmid));
  }

  Future<List<ProxmoxGuest>> _getGuestsOfType(
    String node,
    ProxmoxGuestType type,
  ) async {
    final response = await _authenticatedRequest(
      () => _client.get(
        _uri(
          '/nodes/${_enc(node)}/${type.resourcePath}',
          type == ProxmoxGuestType.qemu ? {'full': 1} : null,
        ),
        headers: _headers,
      ),
    );
    return _readList(
      response,
      (row) => ProxmoxGuest.fromJson(row, type: type, node: node),
      markRead: false,
    );
  }

  Future<List<ProxmoxGuest>> getTemplates(String node) async {
    final guests = await getGuests(node);
    return guests.where((g) => g.isTemplate).toList();
  }

  Future<Map<String, dynamic>> getGuestConfig(
    String node,
    ProxmoxGuestType type,
    int vmid,
  ) async {
    final response = await _authenticatedRequest(
      () => _client.get(
        _uri('/nodes/${_enc(node)}/${type.resourcePath}/$vmid/config'),
        headers: _headers,
      ),
    );
    return _validated(() => _objectData(response));
  }

  Future<void> updateGuestConfig(
    String node,
    ProxmoxGuestType type,
    int vmid,
    Map<String, String> changes,
  ) async {
    _validGuestId(vmid);
    final response = await _authenticatedRequest(
      () => _client.put(
        _uri('/nodes/${_enc(node)}/${type.resourcePath}/$vmid/config'),
        headers: _mutatingHeaders,
        body: changes,
      ),
      readOnly: false,
      target: 'guest:$vmid',
    );
    _dataOf(response);
  }

  /// [action] is one of `start`, `shutdown`, `stop`, `reboot`, `suspend`,
  /// `resume`. Returns the UPID of the resulting task.
  Future<String> powerAction(
    String node,
    ProxmoxGuestType type,
    int vmid,
    String action,
  ) async {
    if (!const {
      'start',
      'shutdown',
      'stop',
      'reboot',
      'suspend',
      'resume',
    }.contains(action)) {
      throw _invalid();
    }
    _validGuestId(vmid);
    final response = await _authenticatedRequest(
      () => _client.post(
        _uri('/nodes/${_enc(node)}/${type.resourcePath}/$vmid/status/$action'),
        headers: _mutatingHeaders,
      ),
      readOnly: false,
      target: 'guest:$vmid',
    );
    return _validated(
      () => proxmoxIdentity(_dataOf(response)),
      markRead: false,
    );
  }

  /// Clones [vmid] (which should be flagged as a template) into a new
  /// guest — the standard Proxmox mechanism for "create from template".
  /// Returns the UPID of the resulting task.
  Future<String> cloneGuest(
    String node,
    ProxmoxGuestType type,
    int vmid, {
    required int newId,
    String? name,
    String? targetStorage,
    String? targetNode,
    bool full = true,
  }) async {
    _validGuestId(vmid);
    _validGuestId(newId);
    if (vmid == newId) throw _invalid();
    final response = await _authenticatedRequest(
      () => _client.post(
        _uri('/nodes/${_enc(node)}/${type.resourcePath}/$vmid/clone'),
        headers: _mutatingHeaders,
        body: {
          'newid': '$newId',
          'full': full ? '1' : '0',
          (type == ProxmoxGuestType.lxc ? 'hostname' : 'name'): ?name,
          if (full && targetStorage != null) 'storage': targetStorage,
          'target': ?targetNode,
        },
      ),
      readOnly: false,
      target: 'guest:$vmid',
    );
    return _validated(
      () => proxmoxIdentity(_dataOf(response)),
      markRead: false,
    );
  }

  /// Cluster-wide allocation avoids collisions with guests on another node.
  Future<int> getNextGuestId() async {
    final response = await _authenticatedRequest(
      () => _client.get(_uri('/cluster/nextid'), headers: _headers),
    );
    return _validated(() {
      final id = int.tryParse('${_dataOf(response)}');
      if (id == null) throw _invalid();
      _validGuestId(id);
      return id;
    });
  }

  Future<List<ProxmoxStorage>> getStorages(String node) async {
    final response = await _authenticatedRequest(
      () =>
          _client.get(_uri('/nodes/${_enc(node)}/storage'), headers: _headers),
    );
    return _readList(response, ProxmoxStorage.fromJson);
  }

  Future<List<ProxmoxBackup>> getBackups(String node, String storage) async {
    final response = await _authenticatedRequest(
      () => _client.get(
        _uri('/nodes/${_enc(node)}/storage/${_enc(storage)}/content', {
          'content': 'backup',
        }),
        headers: _headers,
      ),
    );
    return _readList(response, ProxmoxBackup.fromJson);
  }

  /// Triggers an on-demand `vzdump` backup. Returns the UPID of the task.
  Future<String> triggerBackup(
    String node, {
    required int vmid,
    required String storage,
  }) async {
    _validGuestId(vmid);
    final response = await _authenticatedRequest(
      () => _client.post(
        _uri('/nodes/${_enc(node)}/vzdump'),
        headers: _mutatingHeaders,
        body: {'vmid': '$vmid', 'storage': storage},
      ),
      readOnly: false,
      target: 'guest:$vmid',
    );
    return _validated(
      () => proxmoxIdentity(_dataOf(response)),
      markRead: false,
    );
  }

  Future<List<ProxmoxTask>> getTasks(String node, {int limit = 50}) async {
    final response = await _authenticatedRequest(
      () => _client.get(
        _uri('/nodes/${_enc(node)}/tasks', {'limit': limit}),
        headers: _headers,
      ),
    );
    return _readList(response, ProxmoxTask.fromJson);
  }

  Future<ProxmoxTaskPoll> getTaskStatus(String node, String upid) async {
    final response = await _authenticatedRequest(
      () => _client.get(
        _uri('/nodes/${_enc(node)}/tasks/${_enc(upid)}/status'),
        headers: _headers,
      ),
    );
    return _validated(() {
      final data = _objectData(response);
      if (!const {'running', 'stopped'}.contains(data['status'])) {
        throw _invalid();
      }
      final running = data['status'] == 'running';
      return ProxmoxTaskPoll(
        isRunning: running,
        exitStatus: running ? null : proxmoxText(data['exitstatus']),
      );
    });
  }

  Future<List<String>> getTaskLog(String node, String upid) async {
    final response = await _authenticatedRequest(
      () => _client.get(
        _uri('/nodes/${_enc(node)}/tasks/${_enc(upid)}/log', {'limit': 500}),
        headers: _headers,
      ),
    );
    return _readList(response, (row) {
      if (row['t'] is! String) throw _invalid();
      return row['t'] as String;
    });
  }

  /// The operation keeps running on the server if its screen is closed.
  Future<ProxmoxTaskPoll?> waitForTask(
    String node,
    String upid, {
    bool Function()? shouldContinue,
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(hours: 1),
  }) async {
    final deadline = _now().add(timeout);
    while (shouldContinue?.call() ?? true) {
      final result = await getTaskStatus(node, upid);
      if (!(shouldContinue?.call() ?? true)) return null;
      if (!result.isRunning) {
        if (!result.isSuccess) {
          throw ProxmoxApiException(
            'Task did not complete successfully. Check Activity for details.',
            failure: ProxmoxFailure.server,
          );
        }
        return result;
      }
      if (!_now().isBefore(deadline)) {
        throw ProxmoxApiException(
          'Task is still running. Check Activity for its result.',
        );
      }
      await Future<void>.delayed(interval);
    }
    return null;
  }

  /// Server-provided clients match its noVNC/xterm authentication protocol.
  Uri consolePageUrl(ProxmoxGuest guest) => Uri.parse(config.baseUrl).replace(
    path: '/',
    queryParameters: {
      'console': guest.type == ProxmoxGuestType.qemu ? 'kvm' : 'lxc',
      guest.type == ProxmoxGuestType.qemu ? 'novnc' : 'xtermjs': '1',
      'node': guest.node,
      'vmid': '${guest.vmid}',
      'resize': 'scale',
      'mobile': '0',
    },
  );

  Future<ProxmoxConsoleTicket> vncTicket(String node, int vmid) async {
    _validGuestId(vmid);
    final response = await _authenticatedRequest(
      () => _client.post(
        _uri('/nodes/${_enc(node)}/qemu/$vmid/vncproxy'),
        headers: _mutatingHeaders,
        body: {'websocket': '1'},
      ),
      readOnly: false,
      target: 'guest:$vmid',
    );
    return _validated(() {
      final data = _objectData(response);
      final ticket = data['ticket'];
      final port = proxmoxInteger(data['port'], min: 1);
      if (!_safeSessionValue(ticket) || port == null || port > 65535) {
        throw _invalid();
      }
      return ProxmoxConsoleTicket(ticket: ticket as String, port: port);
    }, markRead: false);
  }

  Future<ProxmoxConsoleTicket> termTicket(String node, int vmid) async {
    _validGuestId(vmid);
    final response = await _authenticatedRequest(
      () => _client.post(
        _uri('/nodes/${_enc(node)}/lxc/$vmid/termproxy'),
        headers: _mutatingHeaders,
      ),
      readOnly: false,
      target: 'guest:$vmid',
    );
    return _validated(() {
      final data = _objectData(response);
      final ticket = data['ticket'];
      final port = proxmoxInteger(data['port'], min: 1);
      if (!_safeSessionValue(ticket) || port == null || port > 65535) {
        throw _invalid();
      }
      return ProxmoxConsoleTicket(ticket: ticket as String, port: port);
    }, markRead: false);
  }

  /// The websocket is served by the API server itself (`config.port`,
  /// normally 8006) — `console.port` is only a query param telling that
  /// server which internal VNC/term port to bridge to, not a port to
  /// connect to directly. The connection also needs the PVE auth cookie
  /// present on the upgrade request itself, not just these query params.
  String consoleWebSocketUrl({
    required String node,
    required ProxmoxGuestType type,
    required int vmid,
    required ProxmoxConsoleTicket console,
  }) {
    final uri = Uri(
      scheme: 'wss',
      host: config.host,
      port: config.port,
      pathSegments: [
        'api2',
        'json',
        'nodes',
        node,
        type.resourcePath,
        '$vmid',
        'vncwebsocket',
      ],
      queryParameters: {'port': '${console.port}', 'vncticket': console.ticket},
    );
    return uri.toString();
  }

  String get authCookieValue => _disposed ? '' : _ticket ?? '';
  void _validGuestId(int value) {
    if (value < 1 || value > 999999999) throw _invalid();
  }

  String _enc(String value) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.length > 4096 ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw _invalid();
    }
    return Uri.encodeComponent(value);
  }

  dynamic _dataOf(http.Response response) {
    _checkActive();
    _checkOk(response);
    try {
      final body = decodeServerJson(response.body);
      if (body is! Map<String, dynamic> || !body.containsKey('data')) {
        throw _invalid();
      }
      return body['data'];
    } on ProxmoxApiException {
      rethrow;
    } catch (_) {
      throw _invalid();
    }
  }

  Map<String, dynamic> _objectData(http.Response response) {
    final data = _dataOf(response);
    if (data is! Map<String, dynamic>) throw _invalid();
    return data;
  }

  List<T> _readList<T>(
    http.Response response,
    T Function(Map<String, dynamic>) parse, {
    bool markRead = true,
  }) => _validated(() {
    final data = _dataOf(response);
    if (data is! List ||
        data.length > 10000 ||
        data.any((row) => row is! Map<String, dynamic>)) {
      throw _invalid();
    }
    final result = data.cast<Map<String, dynamic>>().map(parse).toList();
    final ids = result
        .map(
          (item) => switch (item) {
            ProxmoxNode node => node.name,
            ProxmoxGuest guest => guest.vmid,
            ProxmoxStorage storage => storage.name,
            ProxmoxBackup backup => backup.volumeId,
            ProxmoxTask task => task.upid,
            _ => null,
          },
        )
        .whereType<Object>()
        .toList();
    if (ids.toSet().length != ids.length) throw _invalid();
    return List<T>.unmodifiable(result);
  }, markRead: markRead);
  T _validated<T>(T Function() decode, {bool markRead = true}) {
    try {
      _checkActive();
      final result = decode();
      if (markRead) healthSession?.readSucceeded();
      return result;
    } on ProxmoxApiException catch (error) {
      if (!_disposed) _report(error.failure);
      rethrow;
    } catch (_) {
      if (!_disposed) _report(ProxmoxFailure.invalidResponse);
      throw _invalid();
    }
  }

  ProxmoxApiException _invalid() =>
      ProxmoxApiException('Proxmox returned an invalid response.');
  void _checkOk(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final code = response.statusCode;
    if (code == 401) {
      _ticket = null;
      _csrfToken = null;
      _authenticatedAt = null;
    }
    throw ProxmoxApiException(
      'Proxmox request failed (HTTP $code).',
      statusCode: code,
      failure: switch (code) {
        401 => ProxmoxFailure.authentication,
        403 => ProxmoxFailure.permission,
        >= 500 => ProxmoxFailure.server,
        _ => ProxmoxFailure.invalidResponse,
      },
    );
  }

  void _report(ProxmoxFailure failure) {
    if (failure == ProxmoxFailure.inactive ||
        failure == ProxmoxFailure.actionPending) {
      return;
    }
    healthSession?.failed(switch (failure) {
      ProxmoxFailure.authentication => HealthFailure.authentication,
      ProxmoxFailure.permission => HealthFailure.permission,
      ProxmoxFailure.transport => HealthFailure.transport,
      ProxmoxFailure.timeout => HealthFailure.timeout,
      ProxmoxFailure.server => HealthFailure.server,
      _ => HealthFailure.invalidResponse,
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sessionGeneration++;
    _ticket = null;
    _csrfToken = null;
    _authenticatedAt = null;
    _pendingMutations.clear();
    _client.close();
  }
}
