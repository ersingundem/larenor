import '../../data/media_api_exception.dart';
import '../domain/bazarr_subtitle_request.dart';
import 'bazarr_client.dart';
import 'models/bazarr_wanted_item.dart';

enum BazarrSubtitleAcquisitionStatus {
  confirmed,
  accepted,
  rejected,
  uncertain,
}

final class BazarrSubtitleAcquisitionResult {
  const BazarrSubtitleAcquisitionResult(this.status);

  final BazarrSubtitleAcquisitionStatus status;
}

/// Sends one explicitly confirmed request and performs one read-only
/// observation. The mutation is never retried: a timeout may have committed.
final class BazarrSubtitleAcquisition {
  const BazarrSubtitleAcquisition(this.client);

  final BazarrClient client;

  Future<BazarrSubtitleAcquisitionResult> acquire(
    BazarrSubtitleRequest request,
  ) async {
    try {
      if (request.kind == BazarrSubtitleKind.movie) {
        await client.searchMovieSubtitle(
          radarrId: request.radarrId!,
          language: request.language,
        );
      } else {
        await client.searchEpisodeSubtitle(
          seriesId: request.seriesId!,
          episodeId: request.episodeId!,
          language: request.language,
        );
      }
    } on MediaApiException catch (error) {
      final status = error.statusCode;
      if (status != null && status >= 400 && status < 500) {
        return const BazarrSubtitleAcquisitionResult(
          BazarrSubtitleAcquisitionStatus.rejected,
        );
      }
      return const BazarrSubtitleAcquisitionResult(
        BazarrSubtitleAcquisitionStatus.uncertain,
      );
    } catch (_) {
      return const BazarrSubtitleAcquisitionResult(
        BazarrSubtitleAcquisitionStatus.uncertain,
      );
    }

    List<BazarrWantedItem> wanted;
    try {
      wanted = request.kind == BazarrSubtitleKind.movie
          ? await client.getMissingMovieSubtitles()
          : await client.getMissingEpisodeSubtitles();
    } catch (_) {
      return const BazarrSubtitleAcquisitionResult(
        BazarrSubtitleAcquisitionStatus.accepted,
      );
    }
    final matches = wanted.where(request.matchesItem).toList(growable: false);
    if (matches.length != 1) {
      // An absent row can mean success or that the bounded wanted page moved.
      // Multiple rows mean the provider identity is not authoritative.
      return const BazarrSubtitleAcquisitionResult(
        BazarrSubtitleAcquisitionStatus.accepted,
      );
    }
    final stillMissing = matches.single.missingLanguages.any(
      (language) => request.matchesLanguage(language.code),
    );
    return BazarrSubtitleAcquisitionResult(
      stillMissing
          ? BazarrSubtitleAcquisitionStatus.accepted
          : BazarrSubtitleAcquisitionStatus.confirmed,
    );
  }
}
