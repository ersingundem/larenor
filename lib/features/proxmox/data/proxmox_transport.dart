// Public adapter constructor keeps the transport dependency named inner.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'proxmox_api_exception.dart';

/// A bounded, abortable adapter around the existing endpoint-scoped TLS and
/// redirect policy. No response body or URI appears in transport exceptions.
class ProxmoxTransport extends http.BaseClient {
  ProxmoxTransport({
    required http.Client inner,
    required this.onContact,
    this.requestTimeout = const Duration(seconds: 15),
    this.cloneTimeout = const Duration(seconds: 30),
  }) : _inner = inner;
  final http.Client _inner;
  final void Function() onContact;
  final Duration requestTimeout, cloneTimeout;
  final _aborts = <Completer<void>>{};
  bool _closed = false;

  void _active() {
    if (_closed) {
      throw ProxmoxApiException(
        'Connection is no longer active.',
        failure: ProxmoxFailure.inactive,
      );
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest original) async {
    _active();
    final abort = Completer<void>();
    _aborts.add(abort);
    try {
      final bytes = await original.finalize().toBytes();
      _active();
      final request =
          http.AbortableRequest(
              original.method,
              original.url,
              abortTrigger: abort.future,
            )
            ..headers.addAll(original.headers)
            ..bodyBytes = bytes;
      final response =
          await (() async {
            final streamed = await _inner.send(request);
            _active();
            onContact();
            final body = <int>[];
            await for (final chunk in streamed.stream) {
              _active();
              if (body.length + chunk.length > 2 * 1024 * 1024) {
                throw ProxmoxApiException(
                  'Server response is too large.',
                  failure: ProxmoxFailure.invalidResponse,
                );
              }
              body.addAll(chunk);
            }
            return http.StreamedResponse(
              Stream.value(body),
              streamed.statusCode,
              headers: streamed.headers,
              contentLength: body.length,
              request: original,
            );
          })().timeout(
            original.url.path.endsWith('/clone')
                ? cloneTimeout
                : requestTimeout,
            onTimeout: () {
              if (!abort.isCompleted) abort.complete();
              throw ProxmoxApiException(
                'Proxmox did not respond in time. The action may still be running.',
                failure: ProxmoxFailure.timeout,
              );
            },
          );
      _active();
      return response;
    } on ProxmoxApiException {
      rethrow;
    } on IOException {
      throw ProxmoxApiException(
        'Could not reach Proxmox.',
        failure: ProxmoxFailure.transport,
      );
    } on http.ClientException {
      throw ProxmoxApiException(
        'Could not reach Proxmox.',
        failure: ProxmoxFailure.transport,
      );
    } catch (_) {
      throw ProxmoxApiException(
        'Invalid server response.',
        failure: ProxmoxFailure.invalidResponse,
      );
    } finally {
      _aborts.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final abort in _aborts.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
    _inner.close();
  }
}
