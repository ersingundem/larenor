Never _invalid() => throw const FormatException('invalid_response');

const serverMediaFlowProviderOrder = <String>[
  'seerr',
  'qbittorrent',
  'sonarr',
  'radarr',
  'jellyfin',
];
const serverMediaFlowStageOrder = <String>[
  'request',
  'download',
  'import',
  'playable',
];

final _mediaKey = RegExp(
  r'^(?:movie:tmdb:[1-9][0-9]{0,11}|series:tvdb:[1-9][0-9]{0,11})$',
);

bool validServerMediaKey(String value) =>
    value.length <= 96 && _mediaKey.hasMatch(value);

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 0x7fffffffffffffff) _invalid();
  return value;
}

int _timestamp(Object? value) {
  if (value is! int || value < 1 || value > 253402300799) _invalid();
  return value;
}

List<int> _episodes(Object? value) {
  if (value is! List || value.length > 1000) _invalid();
  final result = value
      .map((item) {
        if (item is! int || item < 1 || item > 10000) _invalid();
        return item;
      })
      .toList(growable: false);
  if ([...result]..sort() case final sorted
      when sorted.join('|') != result.join('|')) {
    _invalid();
  }
  if (result.toSet().length != result.length) _invalid();
  return List.unmodifiable(result);
}

final class ServerMediaFlowSource {
  const ServerMediaFlowSource._({
    required this.provider,
    required this.serviceRevision,
    required this.snapshotRevision,
    required this.observedAt,
  });

  factory ServerMediaFlowSource.fromJson(Object? value) {
    final map = _object(value, {
      'provider',
      'serviceRevision',
      'snapshotRevision',
      'observedAt',
    });
    final provider = map['provider'];
    if (provider is! String ||
        !serverMediaFlowProviderOrder.contains(provider)) {
      _invalid();
    }
    return ServerMediaFlowSource._(
      provider: provider,
      serviceRevision: _revision(map['serviceRevision']),
      snapshotRevision: _revision(map['snapshotRevision']),
      observedAt: _timestamp(map['observedAt']),
    );
  }

  final String provider;
  final int serviceRevision, snapshotRevision, observedAt;

  Map<String, Object> toJson() => {
    'provider': provider,
    'serviceRevision': serviceRevision,
    'snapshotRevision': snapshotRevision,
    'observedAt': observedAt,
  };
}

List<ServerMediaFlowSource> _sources(Object? value, int revision) {
  if (value is! List || value.length != serverMediaFlowProviderOrder.length) {
    _invalid();
  }
  final result = value.map(ServerMediaFlowSource.fromJson).toList();
  if ([for (final item in result) item.provider].join('|') !=
          serverMediaFlowProviderOrder.join('|') ||
      result.any((item) => item.snapshotRevision != revision)) {
    _invalid();
  }
  return List.unmodifiable(result);
}

final class ServerMediaFlowAuthority {
  const ServerMediaFlowAuthority._({
    required this.requestId,
    required this.mediaKey,
    required this.flowRevision,
    required this.sources,
  });

  factory ServerMediaFlowAuthority.fromJson(Object? value) {
    final map = _object(value, {
      'requestId',
      'mediaKey',
      'flowRevision',
      'sources',
    });
    final requestId = map['requestId'];
    final mediaKey = map['mediaKey'];
    final revision = _revision(map['flowRevision']);
    if (requestId is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
        mediaKey is! String ||
        !validServerMediaKey(mediaKey)) {
      _invalid();
    }
    return ServerMediaFlowAuthority._(
      requestId: requestId,
      mediaKey: mediaKey,
      flowRevision: revision,
      sources: _sources(map['sources'], revision),
    );
  }

  final String requestId, mediaKey;
  final int flowRevision;
  final List<ServerMediaFlowSource> sources;
}

final class ServerMediaFlowStage {
  const ServerMediaFlowStage._({
    required this.name,
    required this.state,
    required this.provider,
    required this.sourceRevision,
  });

  factory ServerMediaFlowStage.fromJson(Object? value) {
    final map = _object(value, {'name', 'state', 'provider', 'sourceRevision'});
    final name = map['name'];
    final state = map['state'];
    final provider = map['provider'];
    if (name is! String ||
        !serverMediaFlowStageOrder.contains(name) ||
        state is! String ||
        !{
          'not_started',
          'pending',
          'active',
          'partial',
          'complete',
          'failed',
        }.contains(state) ||
        provider is! String ||
        !serverMediaFlowProviderOrder.contains(provider)) {
      _invalid();
    }
    return ServerMediaFlowStage._(
      name: name,
      state: state,
      provider: provider,
      sourceRevision: _revision(map['sourceRevision']),
    );
  }

  final String name, state, provider;
  final int sourceRevision;
}

final class ServerMediaSeasonCoverage {
  const ServerMediaSeasonCoverage._({
    required this.seasonNumber,
    required this.knownEpisodes,
    required this.downloadedEpisodes,
    required this.importedEpisodes,
    required this.playableEpisodes,
    required this.missingEpisodes,
    required this.requested,
    required this.requestable,
    required this.incomplete,
    required this.missingSeason,
    required this.partialImport,
  });

  factory ServerMediaSeasonCoverage.fromJson(Object? value) {
    final map = _object(value, {
      'seasonNumber',
      'knownEpisodes',
      'downloadedEpisodes',
      'importedEpisodes',
      'playableEpisodes',
      'missingEpisodes',
      'requested',
      'requestable',
      'incomplete',
      'missingSeason',
      'partialImport',
    });
    final season = map['seasonNumber'];
    final known = _episodes(map['knownEpisodes']);
    final downloaded = _episodes(map['downloadedEpisodes']);
    final imported = _episodes(map['importedEpisodes']);
    final playable = _episodes(map['playableEpisodes']);
    final missing = _episodes(map['missingEpisodes']);
    final requested = map['requested'];
    final requestable = map['requestable'];
    final incomplete = map['incomplete'];
    final missingSeason = map['missingSeason'];
    final partialImport = map['partialImport'];
    if (season is! int ||
        season < 0 ||
        season > 1000 ||
        requested is! bool ||
        requestable is! bool ||
        incomplete is! bool ||
        missingSeason is! bool ||
        partialImport is! bool) {
      _invalid();
    }
    final knownSet = known.toSet();
    if (!knownSet.containsAll(downloaded) ||
        !knownSet.containsAll(imported) ||
        !knownSet.containsAll(playable) ||
        missing
            .toSet()
            .difference(knownSet.difference(playable.toSet()))
            .isNotEmpty ||
        knownSet
            .difference(playable.toSet())
            .difference(missing.toSet())
            .isNotEmpty ||
        requestable !=
            (!requested &&
                downloaded.isEmpty &&
                imported.isEmpty &&
                playable.isEmpty) ||
        missingSeason !=
            ((requested || known.isNotEmpty) && playable.isEmpty) ||
        incomplete !=
            (((requested || known.isNotEmpty) && playable.isEmpty) ||
                missing.isNotEmpty) ||
        partialImport !=
            (imported.isNotEmpty &&
                knownSet.difference(imported.toSet()).isNotEmpty)) {
      _invalid();
    }
    return ServerMediaSeasonCoverage._(
      seasonNumber: season,
      knownEpisodes: known,
      downloadedEpisodes: downloaded,
      importedEpisodes: imported,
      playableEpisodes: playable,
      missingEpisodes: missing,
      requested: requested,
      requestable: requestable,
      incomplete: incomplete,
      missingSeason: missingSeason,
      partialImport: partialImport,
    );
  }

  final int seasonNumber;
  final List<int> knownEpisodes, downloadedEpisodes, importedEpisodes;
  final List<int> playableEpisodes, missingEpisodes;
  final bool requested, requestable, incomplete, missingSeason, partialImport;
}

final class ServerMediaFlowDelivery {
  const ServerMediaFlowDelivery._(this.retryAttempt, this.fileCount);

  factory ServerMediaFlowDelivery.fromJson(Object? value) {
    final map = _object(value, {'state', 'retryAttempt', 'fileCount'});
    final retry = map['retryAttempt'];
    final count = map['fileCount'];
    if (map['state'] != 'hardlink_verified' ||
        retry is! int ||
        retry < 1 ||
        retry > 32 ||
        count is! int ||
        count < 1 ||
        count > 4096) {
      _invalid();
    }
    return ServerMediaFlowDelivery._(retry, count);
  }

  final int retryAttempt, fileCount;
}

final class ServerMediaFlowStatus {
  const ServerMediaFlowStatus._({
    required this.mediaKey,
    required this.flowRevision,
    required this.state,
    required this.stages,
    required this.sources,
    required this.seasons,
    required this.delivery,
  });

  factory ServerMediaFlowStatus.fromJson(Object? value) {
    final map = _object(value, {
      'mediaKey',
      'flowRevision',
      'state',
      'stages',
      'sources',
      'seasons',
      'delivery',
    });
    final mediaKey = map['mediaKey'];
    final revision = _revision(map['flowRevision']);
    final state = map['state'];
    final rawStages = map['stages'];
    final rawSeasons = map['seasons'];
    if (mediaKey is! String ||
        !validServerMediaKey(mediaKey) ||
        state is! String ||
        !{
          'not_requested',
          'requested',
          'downloading',
          'importing',
          'partial',
          'playable',
          'failed',
        }.contains(state) ||
        rawStages is! List ||
        rawStages.length != 4 ||
        rawSeasons is! List ||
        rawSeasons.length > 100) {
      _invalid();
    }
    final sources = _sources(map['sources'], revision);
    final stages = rawStages.map(ServerMediaFlowStage.fromJson).toList();
    if ([for (final stage in stages) stage.name].join('|') !=
        serverMediaFlowStageOrder.join('|')) {
      _invalid();
    }
    final expectedProviders = [
      'seerr',
      'qbittorrent',
      mediaKey.startsWith('movie:') ? 'radarr' : 'sonarr',
      'jellyfin',
    ];
    final sourceByProvider = {
      for (final source in sources) source.provider: source,
    };
    for (var index = 0; index < stages.length; index++) {
      final stage = stages[index];
      if (stage.provider != expectedProviders[index] ||
          stage.sourceRevision !=
              sourceByProvider[stage.provider]?.serviceRevision) {
        _invalid();
      }
    }
    final seasons = rawSeasons.map(ServerMediaSeasonCoverage.fromJson).toList();
    if ((mediaKey.startsWith('movie:') && seasons.isNotEmpty) ||
        seasons.map((item) => item.seasonNumber).toSet().length !=
            seasons.length ||
        ([...seasons]..sort(
                  (left, right) =>
                      left.seasonNumber.compareTo(right.seasonNumber),
                ))
                .map((item) => item.seasonNumber)
                .join('|') !=
            seasons.map((item) => item.seasonNumber).join('|')) {
      _invalid();
    }
    final expectedState = stages[3].state == 'complete'
        ? 'playable'
        : stages[3].state == 'partial' || seasons.any((item) => item.incomplete)
        ? 'partial'
        : stages.any((item) => item.state == 'failed')
        ? 'failed'
        : {'active', 'partial', 'complete'}.contains(stages[2].state)
        ? 'importing'
        : {'active', 'complete'}.contains(stages[1].state)
        ? 'downloading'
        : stages[0].state != 'not_started'
        ? 'requested'
        : 'not_requested';
    if (state != expectedState) _invalid();
    return ServerMediaFlowStatus._(
      mediaKey: mediaKey,
      flowRevision: revision,
      state: state,
      stages: List.unmodifiable(stages),
      sources: sources,
      seasons: List.unmodifiable(seasons),
      delivery: map['delivery'] == null
          ? null
          : ServerMediaFlowDelivery.fromJson(map['delivery']),
    );
  }

  final String mediaKey, state;
  final int flowRevision;
  final List<ServerMediaFlowStage> stages;
  final List<ServerMediaFlowSource> sources;
  final List<ServerMediaSeasonCoverage> seasons;
  final ServerMediaFlowDelivery? delivery;
}
