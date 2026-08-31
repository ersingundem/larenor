import 'dart:convert';

import 'package:http/http.dart' as http;

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
  ProxmoxClient({required this.config, http.Client? httpClient})
    : _client =
          httpClient ??
          buildProxmoxHttpClient(allowSelfSigned: config.allowSelfSigned);

  final ProxmoxConfig config;
  final http.Client _client;

  String? _ticket;
  String? _csrfToken;

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

  Future<void> login() async {
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
  }

  Future<List<ProxmoxNode>> getNodes() async {
    final response = await _client
        .get(_uri('/nodes'), headers: _headers)
        .timeout(const Duration(seconds: 15));
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
    return [...results[0], ...results[1]];
  }

  Future<List<ProxmoxGuest>> _getGuestsOfType(
    String node,
    ProxmoxGuestType type,
  ) async {
    final response = await _client
        .get(
          _uri('/nodes/${_enc(node)}/${type.resourcePath}'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
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
    final response = await _client
        .get(
          _uri('/nodes/${_enc(node)}/${type.resourcePath}/$vmid/config'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    return _dataOf(response) as Map<String, dynamic>;
  }

  Future<void> updateGuestConfig(
    String node,
    ProxmoxGuestType type,
    int vmid,
    Map<String, String> changes,
  ) async {
    final response = await _client
        .put(
          _uri('/nodes/${_enc(node)}/${type.resourcePath}/$vmid/config'),
          headers: _mutatingHeaders,
          body: changes,
        )
        .timeout(const Duration(seconds: 15));
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
    final response = await _client
        .post(
          _uri(
            '/nodes/${_enc(node)}/${type.resourcePath}/$vmid/status/$action',
          ),
          headers: _mutatingHeaders,
        )
        .timeout(const Duration(seconds: 15));
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
    final response = await _client
        .post(
          _uri('/nodes/${_enc(node)}/${type.resourcePath}/$vmid/clone'),
          headers: _mutatingHeaders,
          body: {
            'newid': '$newId',
            'full': full ? '1' : '0',
            'name': ?name,
            'storage': ?targetStorage,
            'target': ?targetNode,
          },
        )
        .timeout(const Duration(seconds: 30));
    return _dataOf(response) as String;
  }

  Future<List<ProxmoxStorage>> getStorages(String node) async {
    final response = await _client
        .get(_uri('/nodes/${_enc(node)}/storage'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    final data = _dataOf(response) as List<dynamic>;
    return data
        .map((e) => ProxmoxStorage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<ProxmoxBackup>> getBackups(String node, String storage) async {
    final response = await _client
        .get(
          _uri('/nodes/${_enc(node)}/storage/${_enc(storage)}/content', {
            'content': 'backup',
          }),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
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
    final response = await _client
        .post(
          _uri('/nodes/${_enc(node)}/vzdump'),
          headers: _mutatingHeaders,
          body: {'vmid': '$vmid', 'storage': storage},
        )
        .timeout(const Duration(seconds: 15));
    return _dataOf(response) as String;
  }

  Future<List<ProxmoxTask>> getTasks(String node, {int limit = 50}) async {
    final response = await _client
        .get(
          _uri('/nodes/${_enc(node)}/tasks', {'limit': limit}),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    final data = _dataOf(response) as List<dynamic>;
    return data
        .map((e) => ProxmoxTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ProxmoxTaskPoll> getTaskStatus(String node, String upid) async {
    final response = await _client
        .get(
          _uri('/nodes/${_enc(node)}/tasks/${_enc(upid)}/status'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 15));
    final data = _dataOf(response) as Map<String, dynamic>;
    final running = (data['status'] as String?) == 'running';
    return ProxmoxTaskPoll(
      isRunning: running,
      exitStatus: running ? null : data['exitstatus'] as String?,
    );
  }

  Future<ProxmoxConsoleTicket> vncTicket(String node, int vmid) async {
    final response = await _client
        .post(
          _uri('/nodes/${_enc(node)}/qemu/$vmid/vncproxy'),
          headers: _mutatingHeaders,
          body: {'websocket': '1'},
        )
        .timeout(const Duration(seconds: 15));
    final data = _dataOf(response) as Map<String, dynamic>;
    return ProxmoxConsoleTicket(
      ticket: data['ticket'] as String,
      port: (data['port'] as num).toInt(),
    );
  }

  Future<ProxmoxConsoleTicket> termTicket(String node, int vmid) async {
    final response = await _client
        .post(
          _uri('/nodes/${_enc(node)}/lxc/$vmid/termproxy'),
          headers: _mutatingHeaders,
        )
        .timeout(const Duration(seconds: 15));
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
    required ProxmoxConsoleTicket console,
  }) {
    final uri = Uri(
      scheme: 'wss',
      host: config.host,
      port: config.port,
      path: '/api2/json/nodes/$node/vncwebsocket',
      queryParameters: {'port': '${console.port}', 'vncticket': console.ticket},
    );
    return uri.toString();
  }

  String get authCookieValue => _ticket ?? '';

  String _enc(String value) => Uri.encodeComponent(value);

  dynamic _dataOf(http.Response response) {
    _checkOk(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['data'];
  }

  void _checkOk(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ProxmoxApiException('Request failed (${response.statusCode}).');
    }
  }

  void dispose() => _client.close();
}
