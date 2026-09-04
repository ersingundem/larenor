import 'dart:collection';

import '../../../health/data/integration_health.dart';

enum MediaReadOperation {
  library,
  queue,
  resume,
  recent,
  trending,
  calendar,
  search,
}

/// Identifies an attempted read without storing URLs, queries or credentials.
class MediaReadKey {
  const MediaReadKey(this.service, this.operation);
  final IntegrationId service;
  final MediaReadOperation operation;

  @override
  bool operator ==(Object other) =>
      other is MediaReadKey &&
      service == other.service &&
      operation == other.operation;
  @override
  int get hashCode => Object.hash(service, operation);
}

class MediaReadIssue {
  const MediaReadIssue(this.read, this.failure);
  final MediaReadKey read;
  final HealthFailure failure;

  @override
  bool operator ==(Object other) =>
      other is MediaReadIssue && read == other.read && failure == other.failure;
  @override
  int get hashCode => Object.hash(read, failure);
}

/// Immutable partial data plus evidence from this exact request snapshot.
/// Extending List keeps existing rows/search consumers source-compatible;
/// consumers presenting empty states should also inspect [readIssues].
class MediaReadList<T> extends ListBase<T> {
  MediaReadList(
    Iterable<T> items, {
    Iterable<MediaReadIssue> issues = const [],
    Iterable<MediaReadKey> successfulReads = const [],
  }) : _items = List.unmodifiable(items),
       readIssues = orderedMediaIssues(issues),
       successfulReads = Set.unmodifiable(successfulReads);

  final List<T> _items;
  final List<MediaReadIssue> readIssues;

  /// Read scopes with validated data, including reused index/queue caches.
  /// Freshness comes from the central health timestamps, not cache access.
  final Set<MediaReadKey> successfulReads;
  @override
  int get length => _items.length;
  @override
  set length(int value) => throw UnsupportedError('Media reads are immutable');
  @override
  T operator [](int index) => _items[index];
  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Media reads are immutable');
}

extension MediaReadEvidence<T> on List<T> {
  List<MediaReadIssue> get readIssues => this is MediaReadList<T>
      ? (this as MediaReadList<T>).readIssues
      : const [];
  Set<MediaReadKey> get successfulReads => this is MediaReadList<T>
      ? (this as MediaReadList<T>).successfulReads
      : const {};
}

List<MediaReadIssue> orderedMediaIssues(Iterable<MediaReadIssue> issues) {
  final result = issues.toSet().toList()
    ..sort((a, b) {
      var order = a.read.service.index.compareTo(b.read.service.index);
      if (order != 0) return order;
      order = a.read.operation.index.compareTo(b.read.operation.index);
      return order != 0 ? order : a.failure.index.compareTo(b.failure.index);
    });
  return List.unmodifiable(result);
}
