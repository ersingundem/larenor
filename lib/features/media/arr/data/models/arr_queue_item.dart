class ArrQueueItem {
  const ArrQueueItem({
    required this.id,
    required this.title,
    required this.status,
    this.progressFraction,
    this.timeLeft,
    this.seriesId,
    this.movieId,
    this.tmdbId,
    this.tvdbId,
    this.imdbId,
    this.downloadId,
    this.trackedDownloadState,
    this.trackedDownloadStatus,
    this.seasonNumber,
  });

  final int id;
  final String title;
  final String status;
  final double? progressFraction;
  final String? timeLeft;

  /// The *arr app's own library row id for what's being downloaded —
  /// the join back to [ArrLibraryItem] and to Bazarr's subtitle records.
  final int? seriesId;
  final int? movieId;

  /// External ids lifted out of the nested `series`/`movie` object the
  /// client already asks for via `includeSeries`/`includeMovie`. These
  /// are what let a download be matched to the same title in Jellyfin or
  /// Jellyseerr.
  final int? tmdbId;
  final int? tvdbId;
  final String? imdbId;

  /// The download client's own id for this grab — for a torrent that's
  /// the info hash, i.e. the join to qBittorrent's torrent list.
  final String? downloadId;
  final String? trackedDownloadState;
  final String? trackedDownloadStatus;
  final int? seasonNumber;

  factory ArrQueueItem.fromJson(Map<String, dynamic> json) {
    final size = (json['size'] as num?)?.toDouble();
    final sizeLeft = (json['sizeleft'] as num?)?.toDouble();
    double? progress;
    if (size != null &&
        size.isFinite &&
        size > 0 &&
        sizeLeft != null &&
        sizeLeft.isFinite &&
        sizeLeft >= 0 &&
        sizeLeft <= size) {
      progress = ((size - sizeLeft) / size).clamp(0.0, 1.0);
    }

    final nested =
        json['series'] as Map<String, dynamic>? ??
        json['movie'] as Map<String, dynamic>?;

    return ArrQueueItem(
      id: json['id'] as int? ?? 0,
      title:
          json['title'] as String? ?? nested?['title'] as String? ?? 'Unknown',
      status: json['status'] as String? ?? 'unknown',
      progressFraction: progress,
      timeLeft: json['timeleft'] as String?,
      seriesId: json['seriesId'] as int?,
      movieId: json['movieId'] as int?,
      tmdbId: nested?['tmdbId'] as int?,
      tvdbId: nested?['tvdbId'] as int?,
      imdbId: nested?['imdbId'] as String?,
      downloadId: json['downloadId'] as String?,
      trackedDownloadState: json['trackedDownloadState'] as String?,
      trackedDownloadStatus: json['trackedDownloadStatus'] as String?,
      seasonNumber: json['seasonNumber'] as int?,
    );
  }
}
