import 'jellyseerr_result.dart';

/// Catalogue coverage and Seerr's own media status. Neither proves that this
/// account can play an episode on its currently connected Jellyfin server.
class JellyseerrSeasonSummary {
  const JellyseerrSeasonSummary({
    required this.seasonNumber,
    this.name,
    this.episodeCount,
    this.airDate,
    this.status,
  });

  final int seasonNumber;
  final String? name;
  final int? episodeCount;
  final String? airDate;
  final JellyseerrMediaStatus? status;
}

class JellyseerrDetails {
  const JellyseerrDetails({required this.result, this.seasons = const []});
  final JellyseerrResult result;
  final List<JellyseerrSeasonSummary> seasons;

  factory JellyseerrDetails.fromJson(
    Map<String, dynamic> json, {
    required String mediaType,
    required int mediaId,
  }) {
    const invalid = FormatException('Invalid media details');
    if (json['id'] != mediaId ||
        (json['mediaType'] != null && json['mediaType'] != mediaType)) {
      throw invalid;
    }
    final title = json[mediaType == 'tv' ? 'name' : 'title'];
    if (title is! String || title.trim().isEmpty) throw invalid;
    final result = JellyseerrResult.fromJson({...json, 'mediaType': mediaType});
    if (result.tmdbId != mediaId) throw invalid;
    if (mediaType != 'tv') return JellyseerrDetails(result: result);

    Map<int, Map<String, dynamic>> indexed(Object? value) {
      if (value == null) return {};
      if (value is! List || value.length > 1000) throw invalid;
      final out = <int, Map<String, dynamic>>{};
      for (final row in value) {
        if (row is! Map<String, dynamic>) throw invalid;
        final number = row['seasonNumber'];
        if (number is! int || number < 0 || out.containsKey(number)) {
          throw invalid;
        }
        out[number] = row;
      }
      return out;
    }

    final catalogue = indexed(json['seasons']);
    final mediaInfo = json['mediaInfo'] as Map<String, dynamic>?;
    final tracked = indexed(mediaInfo?['seasons']);
    final numbers = {...catalogue.keys, ...tracked.keys}.toList()..sort();
    final seasons = <JellyseerrSeasonSummary>[];
    for (final number in numbers) {
      final row = catalogue[number];
      final count = row?['episodeCount'];
      final status = tracked[number]?['status'];
      if (count != null && (count is! int || count < 0) ||
          status != null && status is! int) {
        throw invalid;
      }
      seasons.add(
        JellyseerrSeasonSummary(
          seasonNumber: number,
          name: row?['name'] as String?,
          episodeCount: count as int?,
          airDate: row?['airDate'] as String?,
          status: status == null
              ? null
              : JellyseerrMediaStatus.fromCode(status as int),
        ),
      );
    }
    return JellyseerrDetails(
      result: result,
      seasons: List.unmodifiable(seasons),
    );
  }
}
