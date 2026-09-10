import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../../shared/network/server_bound_client.dart';
import '../../server/domain/server_models.dart';
import '../domain/home_resource_models.dart';

final class CoreBoundedDownloadException implements Exception {
  const CoreBoundedDownloadException(this.code);
  final String code;
  @override
  String toString() => 'CoreBoundedDownloadException($code)';
}

final class CoreBoundedBlob {
  CoreBoundedBlob._({
    required Uint8List bytes,
    required this.traceId,
    required this.contentType,
    required this.sha256,
    required this.serviceRevision,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final Uint8List bytes;
  final String traceId, contentType, sha256;
  final int serviceRevision;
  @override
  String toString() => 'CoreBoundedBlob';
}

/// Consumes only the packaged Core v1 bounded stream. It never retries, ranges,
/// resumes, follows redirects, or exposes partial bytes.
final class CoreBoundedDownloadApi {
  CoreBoundedDownloadApi({
    required this.endpoint,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = ServerBoundClient(baseUrl: endpoint.baseUrl, inner: client);

  static const maxBlobBytes = 256 * 1024;
  static const frameHeaderBytes = 49;
  static const maxDataFrames = 64;
  static const wireType = 'application/vnd.larenor.blob-stream.v1';
  final ServerEndpoint endpoint;
  final ServerBoundClient _client;
  final Duration timeout;
  final _pending = <Completer<void>>{};
  bool _closed = false;

  Future<CoreBoundedBlob> download({
    required String token,
    required HomeResourceRecord target,
    required int expectedUserRevision,
    required int expectedServiceRevision,
  }) async {
    if (_closed) throw const CoreBoundedDownloadException('cancelled');
    if (target.kind != HomeResourceKind.resource ||
        expectedUserRevision < 1 ||
        expectedUserRevision > 9223372036854775807 ||
        expectedServiceRevision < 1 ||
        expectedServiceRevision > 9223372036854775807 ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 15)) {
      throw const CoreBoundedDownloadException('invalid_request');
    }
    final abort = Completer<void>();
    _pending.add(abort);
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final request = http.AbortableRequest(
        'POST',
        endpoint.api(
          '/home-resources/${target.context.coreId}/${target.context.homeId}/${target.id}/blob',
        ),
        abortTrigger: abort.future,
      );
      request.headers
        ..['authorization'] = 'Bearer $token'
        ..['accept'] = wireType
        ..['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(
        jsonEncode({
          'expectedUserRevision': expectedUserRevision,
          'expectedRevision': target.revision,
          'expectedAclRevision': target.aclRevision,
          'expectedServiceRevision': expectedServiceRevision,
          'deadlineMs': timeout.inMilliseconds,
        }),
      );
      final response = await _client.send(request).timeout(timeout);
      if (_closed || abort.isCompleted) {
        throw const CoreBoundedDownloadException('cancelled');
      }
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw CoreBoundedDownloadException(switch (response.statusCode) {
          401 => 'unauthorized',
          403 => 'forbidden',
          408 => 'timeout',
          409 => 'revision_conflict',
          413 => 'payload_too_large',
          429 => 'rate_limited',
          _ => response.statusCode >= 500 ? 'server_error' : 'failed',
        });
      }
      final metadata = _metadata(response, expectedServiceRevision);
      final wire = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(timeout)) {
        if (_closed || abort.isCompleted) {
          throw const CoreBoundedDownloadException('cancelled');
        }
        if (wire.length + chunk.length > metadata.framedLength) {
          throw const CoreBoundedDownloadException('late_frame');
        }
        wire.add(chunk);
      }
      if (_closed || abort.isCompleted) {
        throw const CoreBoundedDownloadException('cancelled');
      }
      final raw = wire.takeBytes();
      if (raw.length != metadata.framedLength) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      return _decode(raw, metadata);
    } on CoreBoundedDownloadException {
      rethrow;
    } on TimeoutException {
      throw const CoreBoundedDownloadException('timeout');
    } on http.RequestAbortedException {
      throw CoreBoundedDownloadException(_closed ? 'cancelled' : 'timeout');
    } catch (_) {
      throw CoreBoundedDownloadException(
        _closed
            ? 'cancelled'
            : abort.isCompleted
            ? 'timeout'
            : 'connection_failed',
      );
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
      _pending.remove(abort);
    }
  }

  _Metadata _metadata(http.StreamedResponse response, int expectedRevision) {
    int integer(String name, {required int maximum}) {
      final raw = response.headers[name];
      final value = int.tryParse(raw ?? '');
      if (value == null || value < 0 || value > maximum || '$value' != raw) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      return value;
    }

    final type = response.headers['content-type']?.split(';').first.trim();
    final trace = response.headers['x-larenor-trace-id'];
    final blobType = response.headers['x-larenor-blob-content-type'];
    final digest = response.headers['x-larenor-blob-sha256'];
    final length = integer(
      'x-larenor-blob-content-length',
      maximum: maxBlobBytes,
    );
    final revision = integer(
      'x-larenor-service-revision',
      maximum: 9223372036854775807,
    );
    final framedLength = integer(
      'content-length',
      maximum: maxBlobBytes + frameHeaderBytes * (maxDataFrames + 1),
    );
    if (type != wireType ||
        response.headers['accept-ranges'] != 'none' ||
        response.contentLength != framedLength ||
        trace == null ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(trace) ||
        digest == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        blobType == null ||
        blobType.length > 128 ||
        blobType.isEmpty ||
        blobType.contains(RegExp(r'[\x00-\x1f\x7f-\xff]')) ||
        revision != expectedRevision) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    return _Metadata(trace, length, framedLength, digest, blobType, revision);
  }

  CoreBoundedBlob _decode(Uint8List wire, _Metadata metadata) {
    final bytes = BytesBuilder(copy: false);
    var offset = 0, expectedSequence = 0, dataFrames = 0;
    var finalSeen = false;
    while (offset < wire.length) {
      if (finalSeen) throw const CoreBoundedDownloadException('late_frame');
      if (wire.length - offset < frameHeaderBytes) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      final header = ByteData.sublistView(
        wire,
        offset,
        offset + frameHeaderBytes,
      );
      if (ascii.decode(wire.sublist(offset, offset + 4)) != 'LRB1' ||
          ascii.decode(wire.sublist(offset + 4, offset + 36)) !=
              metadata.traceId ||
          header.getUint64(36) != expectedSequence) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      final flag = header.getUint8(44);
      final length = header.getUint32(45);
      offset += frameHeaderBytes;
      if (flag > 1 || length > 16 * 1024 || offset + length > wire.length) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      if (flag == 1) {
        if (length != 0) {
          throw const CoreBoundedDownloadException('invalid_response');
        }
        finalSeen = true;
      } else {
        dataFrames++;
        if (dataFrames > maxDataFrames ||
            bytes.length + length > maxBlobBytes) {
          throw const CoreBoundedDownloadException('invalid_response');
        }
        bytes.add(wire.sublist(offset, offset + length));
      }
      offset += length;
      expectedSequence++;
    }
    final content = bytes.takeBytes();
    if (!finalSeen ||
        content.length != metadata.contentLength ||
        sha256.convert(content).toString() != metadata.digest) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    return CoreBoundedBlob._(
      bytes: content,
      traceId: metadata.traceId,
      contentType: metadata.contentType,
      sha256: metadata.digest,
      serviceRevision: metadata.serviceRevision,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.toList(growable: false)) {
      if (!pending.isCompleted) pending.complete();
    }
    _pending.clear();
    _client.close();
  }
}

final class _Metadata {
  const _Metadata(
    this.traceId,
    this.contentLength,
    this.framedLength,
    this.digest,
    this.contentType,
    this.serviceRevision,
  );
  final String traceId, digest, contentType;
  final int contentLength, framedLength, serviceRevision;
}
