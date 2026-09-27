import '../../domain/server_models.dart';
import '../../media_catalog/domain/server_media_catalog_models.dart';

const _maximumSegmentSeconds = 8640000;

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _object(Object? raw, Set<String> keys) {
  final value = serverObject(raw);
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

int _revision(Object? raw) {
  if (raw is! int || raw < 1 || raw > 0x7ffffffffffffffe) _invalid();
  return raw;
}

String serverMediaSegmentItemId(String raw) {
  final normalized = raw.replaceAll('-', '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(normalized) ||
      !RegExp(
        r'^(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$',
      ).hasMatch(raw)) {
    throw const LarenorServerException('invalid_request');
  }
  return normalized;
}

enum ServerMediaSegmentKind { intro, outro }

enum ServerMediaSegmentReason {
  available,
  endpointUnsupported,
  contractUnsupported,
  noSegments,
}

/// Exact catalog authority for one segment lookup. Direct Jellyfin metadata is
/// deliberately insufficient because it has no Core installation revisions.
final class ServerMediaSegmentSource {
  const ServerMediaSegmentSource._({
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    required this.jellyfinServiceRevision,
    required this.itemId,
    required this.mediaKey,
  });

  factory ServerMediaSegmentSource.fromCatalog(
    ServerMediaCatalogPage page,
    ServerMediaCatalogItem item,
  ) {
    if (!page.items.any((candidate) => identical(candidate, item))) {
      throw const LarenorServerException('invalid_request');
    }
    return ServerMediaSegmentSource._(
      installationId: page.installationId,
      installationRevision: page.installationRevision,
      snapshotRevision: page.snapshotRevision,
      jellyfinServiceRevision: page.jellyfinServiceRevision,
      itemId: item.itemId,
      mediaKey: item.mediaKey,
    );
  }

  final String installationId, itemId, mediaKey;
  final int installationRevision, snapshotRevision, jellyfinServiceRevision;

  Map<String, Object?> request(String requestId) => {
    'schemaVersion': 1,
    'requestId': requestId,
    'installationId': installationId,
    'expectedInstallationRevision': installationRevision,
    'expectedSnapshotRevision': snapshotRevision,
    'expectedJellyfinServiceRevision': jellyfinServiceRevision,
    'itemId': itemId,
    'mediaKey': mediaKey,
  };
}

final class ServerMediaSegment {
  const ServerMediaSegment._({
    required this.kind,
    required this.start,
    required this.end,
  });

  factory ServerMediaSegment.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'kind',
      'startSeconds',
      'endSeconds',
    });
    final start = value['startSeconds'];
    final end = value['endSeconds'];
    if (value['schemaVersion'] != 1 ||
        start is! int ||
        end is! int ||
        start < 0 ||
        end <= start ||
        end > _maximumSegmentSeconds) {
      _invalid();
    }
    return ServerMediaSegment._(
      kind: switch (value['kind']) {
        'intro' => ServerMediaSegmentKind.intro,
        'outro' => ServerMediaSegmentKind.outro,
        _ => _invalid(),
      },
      start: Duration(seconds: start),
      end: Duration(seconds: end),
    );
  }

  final ServerMediaSegmentKind kind;
  final Duration start, end;

  bool contains(Duration position) => position >= start && position < end;
}

/// An immutable, authority-bound segment read. Epochs belong to the player
/// route and make a retained result easy to reject after source replacement.
final class ServerMediaSegmentResult {
  const ServerMediaSegmentResult._({
    required this.requestId,
    required this.accountRevision,
    required this.source,
    required this.supported,
    required this.reason,
    required this.segments,
    required this.sourceEpoch,
    required this.itemEpoch,
  });

  factory ServerMediaSegmentResult.fromJson(
    Object? raw, {
    required ServerSession session,
    required ServerMediaSegmentSource source,
    required String requestId,
    required int sourceEpoch,
    required int itemEpoch,
  }) {
    final context = session.context;
    final family = session.sessionFamilyId;
    if (context == null || family == null) _invalid();
    final value = _object(raw, {
      'schemaVersion',
      'requestId',
      'authority',
      'supported',
      'reason',
      'segments',
    });
    if (value['schemaVersion'] != 1 || value['requestId'] != requestId) {
      _invalid();
    }
    final authority = _object(value['authority'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'accountId',
      'accountRevision',
      'sessionFamilyId',
      'installationId',
      'installationRevision',
      'snapshotRevision',
      'jellyfinServiceRevision',
      'itemId',
      'mediaKey',
    });
    final accountRevision = _revision(authority['accountRevision']);
    if (authority['schemaVersion'] != 1 ||
        authority['coreId'] != context.coreId ||
        authority['homeId'] != context.homeId ||
        authority['accountId'] != session.user.id ||
        authority['sessionFamilyId'] != family ||
        authority['installationId'] != source.installationId ||
        authority['installationRevision'] != source.installationRevision ||
        authority['snapshotRevision'] != source.snapshotRevision ||
        authority['jellyfinServiceRevision'] !=
            source.jellyfinServiceRevision ||
        authority['itemId'] != source.itemId ||
        authority['mediaKey'] != source.mediaKey) {
      _invalid();
    }
    final supported = value['supported'];
    final reason = switch (value['reason']) {
      'available' => ServerMediaSegmentReason.available,
      'endpoint_unsupported' => ServerMediaSegmentReason.endpointUnsupported,
      'contract_unsupported' => ServerMediaSegmentReason.contractUnsupported,
      'no_segments' => ServerMediaSegmentReason.noSegments,
      _ => _invalid(),
    };
    final rawSegments = value['segments'];
    if (supported is! bool || rawSegments is! List || rawSegments.length > 8) {
      _invalid();
    }
    final segments = rawSegments
        .map(ServerMediaSegment.fromJson)
        .toList(growable: false);
    for (var index = 0; index < segments.length; index++) {
      if (index > 0 && segments[index].start < segments[index - 1].end) {
        _invalid();
      }
    }
    final coherent = switch (reason) {
      ServerMediaSegmentReason.available => supported && segments.isNotEmpty,
      ServerMediaSegmentReason.noSegments => supported && segments.isEmpty,
      ServerMediaSegmentReason.endpointUnsupported ||
      ServerMediaSegmentReason.contractUnsupported =>
        !supported && segments.isEmpty,
    };
    if (!coherent) _invalid();
    return ServerMediaSegmentResult._(
      requestId: requestId,
      accountRevision: accountRevision,
      source: source,
      supported: supported,
      reason: reason,
      segments: List.unmodifiable(segments),
      sourceEpoch: sourceEpoch,
      itemEpoch: itemEpoch,
    );
  }

  final String requestId;
  final int accountRevision, sourceEpoch, itemEpoch;
  final ServerMediaSegmentSource source;
  final bool supported;
  final ServerMediaSegmentReason reason;
  final List<ServerMediaSegment> segments;

  bool isCurrent({required int sourceEpoch, required int itemEpoch}) =>
      this.sourceEpoch == sourceEpoch && this.itemEpoch == itemEpoch;

  ServerMediaSegment? segmentAt(Duration position) {
    if (!supported || position < Duration.zero) return null;
    for (final segment in segments) {
      if (segment.contains(position)) return segment;
      if (position < segment.start) return null;
    }
    return null;
  }
}
