import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../shared/network/server_bound_client.dart';
import '../domain/client_update_models.dart';

/// Reads a bounded manifest; never downloads or installs merely by checking.
class ClientReleaseRepository {
  ClientReleaseRepository({
    required String baseUrl,
    required String accessToken,
    http.Client Function()? clientFactory,
    bool Function()? isCurrent,
  }) : _base = parseServerUrl(baseUrl),
       _token = accessToken,
       _factory = clientFactory ?? http.Client.new,
       _isCurrent = isCurrent ?? (() => true);
  final Uri _base;
  final String _token;
  final http.Client Function() _factory;
  final bool Function() _isCurrent;
  final _active = <http.Client>{};
  bool _closed = false;
  void _check() {
    if (_closed || !_isCurrent()) {
      throw const ClientUpdateException(ClientUpdateFailure.expired);
    }
  }

  Future<ClientRelease?> latest() async {
    _check();
    final client = ServerBoundClient(
      baseUrl: _base.toString(),
      inner: _factory(),
    );
    _active.add(client);
    try {
      return await (() async {
        _check();
        final url = _base.replace(
          path: '${_base.path}/api/v1/client/releases/latest',
          queryParameters: {'platform': 'android', 'channel': 'stable'},
        );
        final request = http.Request('GET', url)
          ..headers['Authorization'] = 'Bearer $_token';
        final response = await client.send(request);
        _check();
        if (response.statusCode == 204) {
          // No representation exists for 204. Do not wait for an upstream
          // stream's cancellation acknowledgement before reporting no release;
          // the finally block closes the transport immediately.
          unawaited(
            response.stream.listen((_) {}).cancel().catchError((Object _) {}),
          );
          return null;
        }
        if (response.statusCode != 200) {
          throw ClientUpdateException(switch (response.statusCode) {
            401 => ClientUpdateFailure.authentication,
            403 => ClientUpdateFailure.permission,
            _ => ClientUpdateFailure.network,
          });
        }
        if ((response.contentLength ?? 0) > 65536) {
          throw const ClientUpdateException(
            ClientUpdateFailure.invalidMetadata,
          );
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          _check();
          if (bytes.length + chunk.length > 65536) {
            throw const ClientUpdateException(
              ClientUpdateFailure.invalidMetadata,
            );
          }
          bytes.addAll(chunk);
        }
        _check();
        return ClientRelease.fromJson(jsonDecode(utf8.decode(bytes)));
      })().timeout(const Duration(seconds: 30));
    } on ClientUpdateException {
      rethrow;
    } on FormatException {
      throw const ClientUpdateException(ClientUpdateFailure.invalidMetadata);
    } catch (_) {
      throw const ClientUpdateException(ClientUpdateFailure.network);
    } finally {
      _active.remove(client);
      client.close();
    }
  }

  void close() {
    _closed = true;
    for (final client in _active.toList()) {
      client.close();
    }
    _active.clear();
  }
}
