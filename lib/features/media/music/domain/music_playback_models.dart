import 'music_models.dart';

enum MusicPlaybackFailure {
  authentication,
  permission,
  transport,
  timeout,
  invalidResponse,
  unavailable,
  unsupported,
  stale,
  invalidSelection,
  sourceChanged,
  expiredIntent,
  invalidIntent,
  busy,
}

enum MusicPlaybackReceiptStatus { accepted, observed, unconfirmed }

class MusicPlaybackException implements Exception {
  const MusicPlaybackException(this.failure, {this.outcomeUnknown = false});
  final MusicPlaybackFailure failure;
  final bool outcomeUnknown;
  @override
  String toString() => 'Music playback could not be completed';
}

/// The exact library/search page which supplied the selected catalog item.
/// Manual URI entry is deliberately absent from the dispatch API.
class MusicCatalogSelection {
  const MusicCatalogSelection.library(MusicLibraryQuery query, this.item)
    : libraryQuery = query,
      searchQuery = null;
  const MusicCatalogSelection.search(MusicSearchQuery query, this.item)
    : libraryQuery = null,
      searchQuery = query;
  final MusicLibraryQuery? libraryQuery;
  final MusicSearchQuery? searchQuery;
  final MusicMediaItem item;
  Object get accountGeneration =>
      libraryQuery?.accountGeneration ?? searchQuery!.accountGeneration;
  String get configEntryId =>
      libraryQuery?.configEntryId ?? searchQuery!.configEntryId;
}

class MusicPlaybackReceipt {
  const MusicPlaybackReceipt({
    required this.status,
    required this.item,
    required this.target,
    required this.acceptedAt,
    this.observedAt,
  });
  final MusicPlaybackReceiptStatus status;
  final MusicMediaItem item;
  final MusicQueueTarget target;
  final DateTime acceptedAt;
  final DateTime? observedAt;
}

class MusicPlaybackState {
  const MusicPlaybackState({
    this.isBusy = false,
    this.receipt,
    this.failure,
    this.outcomeUnknown = false,
  });
  final bool isBusy, outcomeUnknown;
  final MusicPlaybackReceipt? receipt;
  final MusicPlaybackFailure? failure;
}
