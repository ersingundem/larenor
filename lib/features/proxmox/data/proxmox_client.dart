import 'dart:async';

import 'package:http/http.dart' as http;

import '../../../shared/network/server_bound_client.dart';

import 'proxmox_api_exception.dart';
import 'proxmox_config.dart';
import 'proxmox_http_client.dart';
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
/// Uses ticket/cookie auth (`POST /access/ticket`) rather than an API
/// token: Proxmox's `/termproxy` endpoint (container console) only accepts
/// ticket auth, not API tokens, and this client needs console access to
/// both VMs and containers — so ticket auth is the one mode that works
/// everywhere, verified against Proxmox's documented auth flow.
class ProxmoxClient {
  ProxmoxClient({
    required this.config,
    http.Client? httpClient,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _client = ServerBoundClient(
         baseUrl: config.baseUrl,
         inner:
             httpClient ??
             buildProxmoxHttpClient(
               allowSelfSigned: config.allowSelfSigned,
               server: Uri.parse(config.baseUrl),
             ),
       );

  final ProxmoxConfig config;
  final http.Client _client;

  String? _ticket;
  String? _csrfToken;
  final DateTime Function() _now;
  DateTime? _authenticatedAt;
  Future<void>? _loginFuture;

  /// One shared login prevents a dashboard refresh from opening many sessions.
  Future<void> login() => _loginFuture ??= _login().whenComplete(() {
    _loginFuture = null;
  });

  Future<void> ensureAuthenticated() async {
    if (_ticket == null ||
        _authenticatedAt == null ||
        _now().difference(_authenticatedAt!) >= const Duration(minutes: 110)) {
      await login();
    }
  }

  Future<http.Response> _authenticatedRequest(
    Future<http.Response> Function() send,
  ) async {
    await ensureAuthenticated();
    final ticket = _ticket;
    var response = await send();
    // A 401 means authentication rejected the request before execution. Do
    // not retry 403s or transport errors: those could repeat a mutation.
    if (response.statusCode == 401) {
      if (_ticket == ticket) await login();
      response = await send();
    }
    return response;
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
    final response = await _client
        .post(
          _uri('/access/ticket'),
          body: {'username': config.userWithRealm, 'password': config.password},
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw ProxmoxApiException('Login failed (${response.statusCode}).');
    }

    final data = _dataOf(response) as Map<String, dynamic>?;
    final ticket = data?['ticket'] as String?;
    final csrf = data?['CSRFPreventionToken'] as String?;
    if (ticket == null || csrf == null) {
      throw ProxmoxApiException('Unexpected login response.');
    }
    _ticket = ticket;
    _csrfToken = csrf;
    _authenticatedAt = _now();
  }

  Future<List<ProxmoxNode>> getNodes() async {
    final response = await _authenticatedRequest(
      () => _client
          .get(_uri('/nodes'), headers: _headers)
          .timeout(const Duration(seconds: 15)),
    );
    final data = _dataOf(response) as List<dynamic>;
    return data
        .map((e) => ProxmoxNode.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ProxmoxGuest>> getGuests(String node) async {
    final results = await Future.wait([
      _getGuestsOfType(node, ProxmoxGuestType.qemu),
      _getGuestsOfType(node, ProxmoxGuestType.lxc),
    ]);
    return [...results[0], ...results[1]]
      ..sort((a, b) => a.vmid.compareTo(b.vmid));
  }

  Future<List<ProxmoxGuest>> _getGuestsOfType(
    String node,
    ProxmoxGuestType type,
  ) async {
    final response = await _authenticatedRequest(
      () => _client
          .get(
            _uri(
              '/nodes/${_enc(node)}/${type.resourcePath}',
              type == ProxmoxGuestType.qemu ? {'full': 1} : null,
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15)),
    );
    final data = _dataOf(response) as List<dynamic>;
    return data
        .map(
          (e) => ProxmoxGuest.fromJson(
            e as Map<String, dynamic>,
            type: type,
            node: node,
          ),
        )
        .toList();
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
      () => _client
          .get(
            _uri('/nodes/${_enc(node)}/${type.resourcePath}/$vmid/config'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15)),
    );
    return _dataOf(response) as Map<String, dynamic>;
  }

  Future<void> updateGuestConfig(
    String node,
    ProxmoxGuestType type,
    int vmid,
    Map<String, String> changes,
  ) async {
    final response = await _authenticatedRequest(
      () => _client
          .put(
            _uri('/nodes/${_enc(node)}/${type.resourcePath}/$vmid/config'),
            headers: _mutatingHeaders,
            body: changes,
          )
          .timeout(const Duration(seconds: 15)),
    );
    _checkOk(response);
  }

  /// [action] is one of `start`, `shutdown`, `stop`, `reboot`, `suspend`,
  /// `resume`. Returns the UPID of the resulting task.
  Future<String> powerAction(
    String node,
    ProxmoxGuestType type,
    int vmid,
    String action,
  ) async {
    final response = await _authenticatedRequest(
      () => _client
          .post(
            _uri(
              '/nodes/${_enc(node)}/${type.resourcePath}/$vmid/status/$action',
            ),
            headers: _mutatingHeaders,
          )
          .timeout(const Duration(seconds: 15)),
    );
    return _dataOf(response) as String;
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
    final response = await _authenticatedRequest(
      () => _client
          .post(
            _uri('/nodes/${_enc(node)}/${type.resourcePath}/$vmid/clone'),
            headers: _mutatingHeaders,
            body: {
              'newid': '$newId',
              'full': full ? '1' : '0',
              (type == ProxmoxGuestType.lxc ? 'hostname' : 'name'): ?name,
              if (full && targetStorage != null) 'storage': targetStorage,
              'target': ?targetNode,
            },
          )
          .timeout(const Duration(seconds: 30)),
    );
    return _dataOf(response) as String;
  }

  /// Cluster-wide allocation avoids collisions with guests on another node.
  Future<int> getNextGuestId() async {
    final response = await _authenticatedRequest(
      () => _client
          .get(_uri('/cluster/nextid'), headers: _headers)
          .timeout(const Duration(seconds: 15)),
    );
    return int.parse('${_dataOf(response)}');
  }

  Future<List<ProxmoxStorage>> getStorages(String node) async {
    final response = await _authenticatedRequest(
      () => _client
          .get(_uri('/nodes/${_enc(node)}/storage'), headers: _headers)
          .timeout(const Duration(seconds: 15)),
    );
    final data = _dataOf(response) as List<dynamic>;
    return data
        .map((e) => ProxmoxStorage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ProxmoxBackup>> getBackups(String node, String storage) async {
    final response = await _authenticatedRequest(
      () => _client
          .get(
            _uri('/nodes/${_enc(node)}/storage/${_enc(storage)}/content', {
              'content': 'backup',
            }),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15)),
    );
    final data = _dataOf(response) as List<dynamic>;
    return data
        .map((e) => ProxmoxBackup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Triggers an on-demand `vzdump` backup. Returns the UPID of the task.
  Future<String> triggerBackup(
    String node, {
    required int vmid,
    required String storage,
  }) async {
    final response = await _authenticatedRequest(
      () => _client
          .post(
            _uri('/nodes/${_enc(node)}/vzdump'),
            headers: _mutatingHeaders,
            body: {'vmid': '$vmid', 'storage': storage},
          )
          .timeout(const Duration(seconds: 15)),
    );
    return _dataOf(response) as String;
  }

  Future<List<ProxmoxTask>> getTasks(String node, {int limit = 50}) async {
    final response = await _authenticatedRequest(
      () => _client
          .get(
            _uri('/nodes/${_enc(node)}/tasks', {'limit': limit}),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15)),
    );
    final data = _dataOf(response) as List<dynamic>;
    return data
        .map((e) => ProxmoxTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ProxmoxTaskPoll> getTaskStatus(String node, String upid) async {
    final response = await _authenticatedRequest(
      () => _client
          .get(
            _uri('/nodes/${_enc(node)}/tasks/${_enc(upid)}/status'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15)),
    );
    final data = _dataOf(response) as Map<String, dynamic>;
    final running = (data['status'] as String?) == 'running';
    return ProxmoxTaskPoll(
      isRunning: running,
      exitStatus: running ? null : data['exitstatus'] as String?,
    );
  }

  Future<List<String>> getTaskLog(String node, String upid) async {
    final response = await _authenticatedRequest(
      () => _client
          .get(
            _uri('/nodes/${_enc(node)}/tasks/${_enc(upid)}/log', {
              'limit': 500,
            }),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15)),
    );
    final rows = _dataOf(response) as List<dynamic>;
    return rows
        .map((row) => '${(row as Map<String, dynamic>)['t'] ?? ''}')
        .toList();
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
            result.exitStatus ?? 'Task ended without an exit status.',
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
    final response = await _authenticatedRequest(
      () => _client
          .post(
            _uri('/nodes/${_enc(node)}/qemu/$vmid/vncproxy'),
            headers: _mutatingHeaders,
            body: {'websocket': '1'},
          )
          .timeout(const Duration(seconds: 15)),
    );
    final data = _dataOf(response) as Map<String, dynamic>;
    return ProxmoxConsoleTicket(
      ticket: data['ticket'] as String,
      port: (data['port'] as num).toInt(),
    );
  }

  Future<ProxmoxConsoleTicket> termTicket(String node, int vmid) async {
    final response = await _authenticatedRequest(
      () => _client
          .post(
            _uri('/nodes/${_enc(node)}/lxc/$vmid/termproxy'),
            headers: _mutatingHeaders,
          )
          .timeout(const Duration(seconds: 15)),
    );
    final data = _dataOf(response) as Map<String, dynamic>;
    return ProxmoxConsoleTicket(
      ticket: data['ticket'] as String,
      port: (data['port'] as num).toInt(),
    );
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

  String get authCookieValue => _ticket ?? '';

  String _enc(String value) => Uri.encodeComponent(value);

  dynamic _dataOf(http.Response response) {
    _checkOk(response);
    final body = decodeServerJson(response.body) as Map<String, dynamic>;
    return body['data'];
  }

  void _checkOk(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String? detail;
      try {
        final body = decodeServerJson(response.body) as Map<String, dynamic>;
        final errors = body['errors'];
        if (errors is Map && errors.isNotEmpty) {
          detail = errors.entries
              .map((entry) => '${entry.key}: ${entry.value}')
              .join('; ');
        } else if (body['message'] is String) {
          detail = body['message'] as String;
        }
      } on FormatException {
        // Reverse proxies can return HTML; do not display it as an API error.
      } on TypeError {
        // Keep the status code when the error envelope is not an object.
      }
      throw ProxmoxApiException(
        redactServerMessage(
          'Request failed (${response.statusCode}).${detail == null ? '' : ' $detail'}',
          [config.password, _ticket, _csrfToken],
        ),
      );
    }
  }

  void dispose() => _client.close();
}
