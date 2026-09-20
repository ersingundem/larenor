import 'dart:async';
import 'dart:convert';
import 'dart:math';
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
    required this.requestId,
    required this.traceId,
    required this.contentType,
    required this.sha256,
    required this.serviceRevision,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final Uint8List bytes;
  final String requestId, traceId, contentType, sha256;
  final int serviceRevision;
  @override
  String toString() => 'CoreBoundedBlob';
}

/// A picker result whose bytes are already bounded and detached from any path.
final class CoreBoundedUploadSource {
  factory CoreBoundedUploadSource({
    required String filename,
    required String contentType,
    required Uint8List bytes,
  }) {
    if (filename.isEmpty ||
        filename.length > 255 ||
        filename.contains(RegExp(r'[/\\\x00-\x1f\x7f]')) ||
        bytes.isEmpty ||
        bytes.length > CoreBoundedDownloadApi.maxBlobBytes ||
        !_contentType.hasMatch(contentType) ||
        contentType.contains(RegExp(r'[\r\n]'))) {
      throw const CoreBoundedDownloadException('invalid_request');
    }
    return CoreBoundedUploadSource._(
      filename,
      contentType,
      Uint8List.fromList(bytes).asUnmodifiableView(),
    );
  }

  const CoreBoundedUploadSource._(this.filename, this.contentType, this.bytes);
  static final _contentType = RegExp(r'^[A-Za-z0-9!#$&^_.+\-/;= ]{1,128}$');
  final String filename, contentType;
  final Uint8List bytes;
  @override
  String toString() => 'CoreBoundedUploadSource';
}

final class CoreBoundedBlobDescriptor {
  const CoreBoundedBlobDescriptor._({
    required this.resourceId,
    required this.serviceRevision,
    required this.contentLength,
    required this.sha256,
    required this.contentType,
    required this.createdAt,
    required this.updatedAt,
  });

  factory CoreBoundedBlobDescriptor.fromJson(
    Object? raw, {
    required String expectedResourceId,
  }) {
    const keys = {
      'resourceId',
      'serviceRevision',
      'contentLength',
      'sha256',
      'contentType',
      'createdAt',
      'updatedAt',
    };
    if (raw is! Map ||
        raw.length != keys.length ||
        !keys.every(raw.containsKey)) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    final resourceId = raw['resourceId'];
    final revision = raw['serviceRevision'];
    final length = raw['contentLength'];
    final digest = raw['sha256'];
    final contentType = raw['contentType'];
    final created = raw['createdAt'];
    final updated = raw['updatedAt'];
    final createdSeconds = created is num ? created.toDouble() : double.nan;
    final updatedSeconds = updated is num ? updated.toDouble() : double.nan;
    if (resourceId != expectedResourceId ||
        resourceId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(resourceId) ||
        revision is! int ||
        revision < 1 ||
        revision > 9223372036854775807 ||
        length is! int ||
        length < 1 ||
        length > CoreBoundedDownloadApi.maxBlobBytes ||
        digest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        contentType is! String ||
        !CoreBoundedUploadSource._contentType.hasMatch(contentType) ||
        contentType.contains(RegExp(r'[\r\n]')) ||
        !createdSeconds.isFinite ||
        !updatedSeconds.isFinite ||
        createdSeconds < 0 ||
        updatedSeconds < createdSeconds ||
        updatedSeconds > 8640000000000) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    return CoreBoundedBlobDescriptor._(
      resourceId: resourceId,
      serviceRevision: revision,
      contentLength: length,
      sha256: digest,
      contentType: contentType,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (createdSeconds * 1000).round(),
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (updatedSeconds * 1000).round(),
      ),
    );
  }

  final String resourceId, sha256, contentType;
  final int serviceRevision, contentLength;
  final DateTime createdAt, updatedAt;

  bool authenticates(String digest, int length) =>
      sha256 == digest && contentLength == length;

  bool authenticatesBlob(CoreBoundedBlob blob) =>
      serviceRevision == blob.serviceRevision &&
      contentLength == blob.bytes.length &&
      sha256 == blob.sha256 &&
      contentType == blob.contentType;

  @override
  String toString() => 'CoreBoundedBlobDescriptor';
}

final class CoreBoundedBlobUploadResult {
  const CoreBoundedBlobUploadResult._(
    this.requestId,
    this.descriptor,
    this.sourceDigest,
  );
  final String requestId, sourceDigest;
  final CoreBoundedBlobDescriptor descriptor;
  @override
  String toString() => 'CoreBoundedBlobUploadResult';
}

enum CoreBoundedTransferState { accepted, completed, interrupted }

enum CoreBoundedTransferEventKind { baseline, accepted, result }

/// Public, content-free proof retained by Core for one bounded transfer.
final class CoreBoundedTransferReceipt {
  const CoreBoundedTransferReceipt._({
    required this.requestId,
    required this.traceId,
    required this.state,
    required this.contentLength,
    required this.sha256,
    required this.contentType,
    required this.serviceRevision,
    required this.createdAt,
    required this.updatedAt,
    required this._createdSeconds,
  });

  factory CoreBoundedTransferReceipt.fromJson(Object? raw) {
    const keys = {
      'requestId',
      'traceId',
      'state',
      'contentLength',
      'sha256',
      'contentType',
      'serviceRevision',
      'createdAt',
      'updatedAt',
    };
    if (raw is! Map ||
        raw.length != keys.length ||
        !keys.every(raw.containsKey)) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    final requestId = raw['requestId'];
    final traceId = raw['traceId'];
    final sha256 = raw['sha256'];
    final contentType = raw['contentType'];
    final contentLength = raw['contentLength'];
    final serviceRevision = raw['serviceRevision'];
    final created = raw['createdAt'];
    final updated = raw['updatedAt'];
    final state = switch (raw['state']) {
      'accepted' => CoreBoundedTransferState.accepted,
      'completed' => CoreBoundedTransferState.completed,
      'interrupted' => CoreBoundedTransferState.interrupted,
      _ => null,
    };
    final createdSeconds = created is num ? created.toDouble() : double.nan;
    final updatedSeconds = updated is num ? updated.toDouble() : double.nan;
    if (requestId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
        traceId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(traceId) ||
        traceId != requestId ||
        state == null ||
        contentLength is! int ||
        contentLength < 0 ||
        contentLength > CoreBoundedDownloadApi.maxBlobBytes ||
        sha256 is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
        contentType is! String ||
        contentType.isEmpty ||
        contentType.length > 128 ||
        !RegExp(r'^[A-Za-z0-9!#$&^_.+\-/;= ]{1,128}$').hasMatch(contentType) ||
        serviceRevision is! int ||
        serviceRevision < 1 ||
        serviceRevision > 9223372036854775807 ||
        !createdSeconds.isFinite ||
        !updatedSeconds.isFinite ||
        createdSeconds < 0 ||
        updatedSeconds < createdSeconds ||
        updatedSeconds > 8640000000000) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    return CoreBoundedTransferReceipt._(
      requestId: requestId,
      traceId: traceId,
      state: state,
      contentLength: contentLength,
      sha256: sha256,
      contentType: contentType,
      serviceRevision: serviceRevision,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (createdSeconds * 1000).round(),
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (updatedSeconds * 1000).round(),
      ),
      createdSeconds: createdSeconds,
    );
  }

  final String requestId, traceId, sha256, contentType;
  final CoreBoundedTransferState state;
  final int contentLength, serviceRevision;
  final DateTime createdAt, updatedAt;
  final double _createdSeconds;

  @override
  String toString() => 'CoreBoundedTransferReceipt';

  bool authenticates(CoreBoundedBlob blob) =>
      state == CoreBoundedTransferState.completed &&
      requestId == blob.requestId &&
      traceId == blob.traceId &&
      contentLength == blob.bytes.length &&
      sha256 == blob.sha256 &&
      contentType == blob.contentType &&
      serviceRevision == blob.serviceRevision;

  bool sameEvidence(CoreBoundedTransferReceipt other) =>
      requestId == other.requestId &&
      traceId == other.traceId &&
      state == other.state &&
      contentLength == other.contentLength &&
      sha256 == other.sha256 &&
      contentType == other.contentType &&
      serviceRevision == other.serviceRevision &&
      createdAt == other.createdAt &&
      updatedAt == other.updatedAt;
}

final class CoreBoundedTransferEvent {
  const CoreBoundedTransferEvent._(
    this.sequence,
    this.kind,
    this.actorId,
    this.receipt,
  );

  factory CoreBoundedTransferEvent.fromJson(Object? raw) {
    const keys = {'sequence', 'kind', 'actorId', 'receipt'};
    if (raw is! Map ||
        raw.length != keys.length ||
        !keys.every(raw.containsKey)) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    final sequence = raw['sequence'];
    final actorId = raw['actorId'];
    final kind = switch (raw['kind']) {
      'baseline' => CoreBoundedTransferEventKind.baseline,
      'accepted' => CoreBoundedTransferEventKind.accepted,
      'result' => CoreBoundedTransferEventKind.result,
      _ => null,
    };
    final receipt = CoreBoundedTransferReceipt.fromJson(raw['receipt']);
    if (sequence is! int ||
        sequence < 1 ||
        sequence > 2048 ||
        actorId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(actorId) ||
        kind == null ||
        kind == CoreBoundedTransferEventKind.accepted &&
            receipt.state != CoreBoundedTransferState.accepted ||
        kind == CoreBoundedTransferEventKind.result &&
            receipt.state == CoreBoundedTransferState.accepted) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    return CoreBoundedTransferEvent._(sequence, kind, actorId, receipt);
  }

  final int sequence;
  final CoreBoundedTransferEventKind kind;
  final String actorId;
  final CoreBoundedTransferReceipt receipt;

  @override
  String toString() => 'CoreBoundedTransferEvent';
}

final class CoreBoundedTransferEventPage {
  const CoreBoundedTransferEventPage._(
    this.chainId,
    this.headSequence,
    this.events,
    this.nextAfter,
  );

  factory CoreBoundedTransferEventPage.fromJson(
    Object? raw, {
    required HomeResourceRecord target,
    required int? after,
    required int limit,
  }) {
    const keys = {
      'schemaVersion',
      'ref',
      'chainId',
      'headSequence',
      'events',
      'nextAfter',
      'verified',
    };
    if (raw is! Map ||
        raw.length != keys.length ||
        !keys.every(raw.containsKey)) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    final ref = raw['ref'];
    const refKeys = {'schemaVersion', 'coreId', 'homeId', 'kind', 'id'};
    final chainId = raw['chainId'];
    final head = raw['headSequence'];
    final values = raw['events'];
    final next = raw['nextAfter'];
    if (raw['schemaVersion'] is! int ||
        raw['schemaVersion'] != 1 ||
        raw['verified'] is! bool ||
        raw['verified'] != true ||
        ref is! Map ||
        ref.length != refKeys.length ||
        !refKeys.every(ref.containsKey) ||
        ref['schemaVersion'] is! int ||
        ref['schemaVersion'] != 1 ||
        ref['coreId'] != target.context.coreId ||
        ref['homeId'] != target.context.homeId ||
        ref['kind'] != 'resource' ||
        ref['id'] != target.id ||
        chainId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(chainId) ||
        head is! int ||
        head < 0 ||
        head > 2048 ||
        values is! List ||
        values.length > limit ||
        next != null && (next is! int || next < 1 || next > 2048)) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    final events = List<CoreBoundedTransferEvent>.unmodifiable(
      values.map(CoreBoundedTransferEvent.fromJson),
    );
    var expected = (after ?? 0) + 1;
    for (final event in events) {
      if (event.sequence != expected || event.sequence > head) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      expected++;
    }
    if (events.isEmpty) {
      if (next != null || head != (after ?? 0)) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
    } else {
      final last = events.last.sequence;
      if (next == null && last != head ||
          next != null &&
              (events.length != limit || next != last || next >= head)) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
    }
    return CoreBoundedTransferEventPage._(chainId, head, events, next as int?);
  }

  final String chainId;
  final int headSequence;
  final List<CoreBoundedTransferEvent> events;
  final int? nextAfter;

  @override
  String toString() => 'CoreBoundedTransferEventPage';
}

/// Consumes only the packaged Core v1 bounded stream. It never retries, ranges,
/// resumes, follows redirects, or exposes partial bytes.
final class CoreBoundedDownloadApi {
  CoreBoundedDownloadApi({
    required this.endpoint,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
    String Function()? requestId,
  }) : _client = ServerBoundClient(baseUrl: endpoint.baseUrl, inner: client),
       _requestId = requestId ?? _randomId;

  static const maxBlobBytes = 256 * 1024;
  static const frameHeaderBytes = 49;
  static const maxDataFrames = 64;
  static const wireType = 'application/vnd.larenor.blob-stream.v1';
  final ServerEndpoint endpoint;
  final ServerBoundClient _client;
  final String Function() _requestId;
  final Duration timeout;
  final _pending = <Completer<void>>{};
  bool _closed = false;

  static String _statusCode(int statusCode) => switch (statusCode) {
    401 => 'unauthorized',
    403 => 'forbidden',
    404 => 'not_found',
    408 => 'timeout',
    409 => 'revision_conflict',
    413 => 'payload_too_large',
    429 => 'rate_limited',
    _ => statusCode >= 500 ? 'server_error' : 'failed',
  };

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<CoreBoundedBlob> download({
    required String token,
    required HomeResourceRecord target,
    required int expectedUserRevision,
    required int expectedServiceRevision,
  }) async {
    if (_closed) throw const CoreBoundedDownloadException('cancelled');
    final requestId = _requestId();
    if (target.kind != HomeResourceKind.resource ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
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
          'requestId': requestId,
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
        throw CoreBoundedDownloadException(_statusCode(response.statusCode));
      }
      final metadata = _metadata(response, expectedServiceRevision, requestId);
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

  void _target(HomeResourceRecord target) {
    if (target.kind != HomeResourceKind.resource) {
      throw const CoreBoundedDownloadException('invalid_request');
    }
  }

  String _transferPath(HomeResourceRecord target) =>
      '/home-resources/${target.context.coreId}/${target.context.homeId}/${target.id}/blob/transfers';

  String _blobPath(HomeResourceRecord target) =>
      '/home-resources/${target.context.coreId}/${target.context.homeId}/${target.id}/blob';

  Future<Object?> _readJson({
    required String token,
    required String path,
    Map<String, String>? query,
  }) async {
    if (_closed) throw const CoreBoundedDownloadException('cancelled');
    final abort = Completer<void>();
    _pending.add(abort);
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      var uri = endpoint.api(path);
      if (query != null) uri = uri.replace(queryParameters: query);
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: abort.future,
      );
      request.headers
        ..['authorization'] = 'Bearer $token'
        ..['accept'] = 'application/json';
      final response = await _client.send(request).timeout(timeout);
      if (_closed || abort.isCompleted) {
        throw const CoreBoundedDownloadException('cancelled');
      }
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw CoreBoundedDownloadException(switch (response.statusCode) {
          401 => 'unauthorized',
          403 => 'forbidden',
          404 => 'not_found',
          408 => 'timeout',
          409 => 'revision_conflict',
          429 => 'rate_limited',
          _ => response.statusCode >= 500 ? 'server_error' : 'failed',
        });
      }
      if (response.headers['content-type']?.split(';').first.trim() !=
          'application/json') {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(timeout)) {
        if (_closed || abort.isCompleted) {
          throw const CoreBoundedDownloadException('cancelled');
        }
        if (bytes.length + chunk.length > 64 * 1024) {
          throw const CoreBoundedDownloadException('invalid_response');
        }
        bytes.add(chunk);
      }
      try {
        return decodeServerJson(utf8.decode(bytes.takeBytes()));
      } on FormatException {
        throw const CoreBoundedDownloadException('invalid_response');
      }
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

  Future<CoreBoundedTransferReceipt> receipt({
    required String token,
    required HomeResourceRecord target,
    required String requestId,
  }) async {
    _target(target);
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId)) {
      throw const CoreBoundedDownloadException('invalid_request');
    }
    final raw = await _readJson(
      token: token,
      path: '${_transferPath(target)}/$requestId',
    );
    if (raw is! Map || raw.length != 1 || !raw.containsKey('receipt')) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    final value = CoreBoundedTransferReceipt.fromJson(raw['receipt']);
    if (value.requestId != requestId) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    return value;
  }

  Future<CoreBoundedBlobDescriptor> descriptor({
    required String token,
    required HomeResourceRecord target,
  }) async {
    _target(target);
    final raw = await _readJson(
      token: token,
      path: '${_blobPath(target)}/descriptor',
    );
    if (raw is! Map || raw.length != 1 || !raw.containsKey('blob')) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    return CoreBoundedBlobDescriptor.fromJson(
      raw['blob'],
      expectedResourceId: target.id,
    );
  }

  Future<CoreBoundedBlobUploadResult> upload({
    required String token,
    required HomeResourceRecord target,
    required int expectedUserRevision,
    required int expectedServiceRevision,
    required CoreBoundedUploadSource source,
  }) async {
    if (_closed) throw const CoreBoundedDownloadException('cancelled');
    _target(target);
    final requestId = _requestId();
    if (!target.canWrite ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
        expectedUserRevision < 1 ||
        expectedUserRevision > 9223372036854775807 ||
        expectedServiceRevision < 0 ||
        expectedServiceRevision >= 9223372036854775807 ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 15)) {
      throw const CoreBoundedDownloadException('invalid_request');
    }
    final digest = sha256.convert(source.bytes).toString();
    final abort = Completer<void>();
    _pending.add(abort);
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final request = http.AbortableRequest(
        'PUT',
        endpoint.api('${_blobPath(target)}/uploads/$requestId'),
        abortTrigger: abort.future,
      );
      request.headers
        ..['authorization'] = 'Bearer $token'
        ..['accept'] = 'application/json'
        ..['content-type'] = source.contentType
        ..['x-larenor-upload-request-id'] = requestId
        ..['x-larenor-content-sha256'] = digest
        ..['x-larenor-expected-user-revision'] = '$expectedUserRevision'
        ..['x-larenor-expected-resource-revision'] = '${target.revision}'
        ..['x-larenor-expected-acl-revision'] = '${target.aclRevision}'
        ..['x-larenor-expected-service-revision'] = '$expectedServiceRevision';
      request.bodyBytes = source.bytes;
      final response = await _client.send(request).timeout(timeout);
      if (_closed || abort.isCompleted) {
        throw const CoreBoundedDownloadException('cancelled');
      }
      if (response.statusCode != 200 && response.statusCode != 201) {
        await response.stream.listen((_) {}).cancel();
        throw CoreBoundedDownloadException(_statusCode(response.statusCode));
      }
      final raw = await _json(response, abort);
      if (raw is! Map || raw.length != 1 || !raw.containsKey('blob')) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      final blob = raw['blob'];
      if (blob is! Map || blob['requestId'] != requestId) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      final descriptorJson = Map<Object?, Object?>.from(blob)
        ..remove('requestId');
      final descriptor = CoreBoundedBlobDescriptor.fromJson(
        descriptorJson,
        expectedResourceId: target.id,
      );
      if (descriptor.serviceRevision != expectedServiceRevision + 1 ||
          descriptor.contentLength != source.bytes.length ||
          descriptor.sha256 != digest ||
          descriptor.contentType != source.contentType) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      return CoreBoundedBlobUploadResult._(requestId, descriptor, digest);
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

  Future<Object?> _json(
    http.StreamedResponse response,
    Completer<void> abort,
  ) async {
    if (response.headers['content-type']?.split(';').first.trim() !=
        'application/json') {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(timeout)) {
      if (_closed || abort.isCompleted) {
        throw const CoreBoundedDownloadException('cancelled');
      }
      if (bytes.length + chunk.length > 64 * 1024) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      bytes.add(chunk);
    }
    try {
      return decodeServerJson(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      throw const CoreBoundedDownloadException('invalid_response');
    }
  }

  Future<List<CoreBoundedTransferReceipt>> history({
    required String token,
    required HomeResourceRecord target,
    int limit = 20,
  }) async {
    _target(target);
    if (limit < 1 || limit > 50) {
      throw const CoreBoundedDownloadException('invalid_request');
    }
    final raw = await _readJson(
      token: token,
      path: _transferPath(target),
      query: {'limit': '$limit'},
    );
    if (raw is! Map ||
        raw.length != 1 ||
        !raw.containsKey('receipts') ||
        raw['receipts'] is! List ||
        (raw['receipts'] as List).length > limit ||
        (raw['receipts'] as List).length > 50) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    final values = List<CoreBoundedTransferReceipt>.unmodifiable(
      (raw['receipts'] as List).map(CoreBoundedTransferReceipt.fromJson),
    );
    final ids = <String>{};
    for (var index = 0; index < values.length; index++) {
      final value = values[index];
      if (!ids.add(value.requestId)) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
      if (index == 0) continue;
      final previous = values[index - 1];
      final order = previous._createdSeconds.compareTo(value._createdSeconds);
      if (order < 0 ||
          order == 0 && previous.requestId.compareTo(value.requestId) <= 0) {
        throw const CoreBoundedDownloadException('invalid_response');
      }
    }
    return values;
  }

  Future<CoreBoundedTransferEventPage> eventHistory({
    required String token,
    required HomeResourceRecord target,
    int? after,
    int limit = 50,
  }) async {
    _target(target);
    if (limit < 1 ||
        limit > 50 ||
        after != null && (after < 1 || after > 2048)) {
      throw const CoreBoundedDownloadException('invalid_request');
    }
    final raw = await _readJson(
      token: token,
      path: '${_transferPath(target)}/events',
      query: {if (after != null) 'after': '$after', 'limit': '$limit'},
    );
    return CoreBoundedTransferEventPage.fromJson(
      raw,
      target: target,
      after: after,
      limit: limit,
    );
  }

  Future<CoreBoundedTransferReceipt> verifyCompleted({
    required String token,
    required HomeResourceRecord target,
    required CoreBoundedBlob blob,
  }) async {
    final exact = await receipt(
      token: token,
      target: target,
      requestId: blob.requestId,
    );
    if (!exact.authenticates(blob)) {
      throw const CoreBoundedDownloadException('invalid_response');
    }
    return exact;
  }

  _Metadata _metadata(
    http.StreamedResponse response,
    int expectedRevision,
    String expectedTrace,
  ) {
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
        trace != expectedTrace ||
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
      requestId: metadata.traceId,
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
