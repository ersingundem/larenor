import '../../ha_playback/domain/ha_media_inventory.dart';
import '../../ha_playback/domain/ha_playback_models.dart';
import '../domain/music_models.dart';
import 'music_api.dart';
import 'music_parser.dart';

class MusicRepository {
  MusicRepository({
    required this.api,
    required this.loadInventory,
    required this.accountGeneration,
    required this.isCurrent,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final MusicAssistantApi api;
  final Future<HaMediaInventory> Function() loadInventory;
  final Object accountGeneration;
  final bool Function() isCurrent;
  final DateTime Function() now;
  bool _closed = false;
  MusicDiscovery? _latest;
  Future<MusicDiscovery>? _discovering;
  bool get current => !_closed && isCurrent();
  void close() {
    _closed = true;
    _latest = null;
  }

  void _check() {
    if (!current) throw const MusicException(MusicFailure.stale);
  }

  Future<MusicDiscovery> discover() {
    _check();
    final pending = _discovering;
    if (pending != null) return pending;
    return _discovering = _discover().whenComplete(() => _discovering = null);
  }

  Future<MusicDiscovery> _discover() async {
    final issues = <MusicDiscoverySource, MusicFailure>{};
    var entries = <MusicAssistantEntry>[];
    HaMediaInventory? inventory;
    await Future.wait<void>([
      () async {
        try {
          entries = parseMusicEntries(
            await api.configEntries(isCurrent: () => current),
          );
        } catch (error) {
          issues[MusicDiscoverySource.configEntries] = classifyMusicFailure(
            error,
          );
        }
      }(),
      () async {
        try {
          inventory = await loadInventory();
        } catch (error) {
          issues[MusicDiscoverySource.inventory] = classifyMusicFailure(error);
        }
      }(),
    ]);
    _check();
    final found = inventory;
    final targets = <MusicQueueTarget>[];
    final services = <MusicReadService>{};
    if (found != null) {
      if (!found.registryAvailable) {
        issues[MusicDiscoverySource.registry] = found.registryFailure == null
            ? MusicFailure.unavailable
            : classifyMusicFailureFromRegistry(found);
      } else {
        final entryIds = entries.map((entry) => entry.id).toSet();
        for (final target in found.targets) {
          if (target.platform == 'music_assistant' &&
              target.registryId != null &&
              target.supportsPlayMedia &&
              entryIds.contains(target.configEntryId)) {
            targets.add(
              MusicQueueTarget(
                entityId: target.entityId,
                configEntryId: target.configEntryId!,
                name: target.name,
                registryId: target.registryId,
                deviceId: target.deviceId,
                available: target.available,
                enabled: target.enabled,
              ),
            );
          }
        }
      }
      try {
        final domain = found.services['music_assistant'];
        if (domain != null) {
          final descriptors = musicObject(domain);
          for (final entry in const {
            'search': MusicReadService.search,
            'get_library': MusicReadService.getLibrary,
            'get_queue': MusicReadService.getQueue,
          }.entries) {
            final raw = descriptors[entry.key];
            if (raw == null) continue;
            final descriptor = musicObject(raw),
                response = descriptor['response'];
            if (response != null) {
              final schema = musicObject(response);
              if (schema['optional'] != null && schema['optional'] is! bool) {
                throw const MusicException(MusicFailure.invalidResponse);
              }
              services.add(entry.value);
            }
          }
        }
      } catch (error) {
        services.clear();
        issues[MusicDiscoverySource.services] = classifyMusicFailure(error);
      }
    }
    return _latest = MusicDiscovery(
      accountGeneration: accountGeneration,
      readAt: now().toUtc(),
      inventory: inventory,
      entries: entries,
      queueTargets: targets,
      services: services,
      issues: issues,
    );
  }

  Future<MusicDiscovery> _select(
    Object generation,
    String entryId,
    MusicReadService service,
  ) async {
    _check();
    if (!identical(generation, accountGeneration) || !_identifier(entryId)) {
      throw const MusicException(MusicFailure.invalidSelection);
    }
    // Read-only discovery is shared and refreshed at most once per minute.
    // Revalidate the config entry and entity registry before using an old list.
    var discovery = _latest;
    final pending = _discovering;
    if (pending != null) {
      discovery = await pending;
      _check();
    }
    if (discovery == null ||
        now().isBefore(discovery.readAt) ||
        now().difference(discovery.readAt) >= const Duration(minutes: 1)) {
      discovery = await discover();
    }
    _check();
    for (final source in [
      MusicDiscoverySource.configEntries,
      MusicDiscoverySource.inventory,
      MusicDiscoverySource.services,
    ]) {
      final issue = discovery.issues[source];
      if (issue != null) throw MusicException(issue);
    }
    final entry = discovery.entries
        .where((entry) => entry.id == entryId)
        .firstOrNull;
    if (entry == null) {
      throw const MusicException(MusicFailure.invalidSelection);
    }
    if (!entry.isLoaded) throw const MusicException(MusicFailure.unavailable);
    if (!discovery.services.contains(service)) {
      throw const MusicException(MusicFailure.unsupported);
    }
    return discovery;
  }

  Future<MusicLibraryPage> library(MusicLibraryQuery query) async {
    if (query.limit < 1 ||
        query.limit > 100 ||
        query.offset < 0 ||
        query.offset > 1000000) {
      throw const MusicException(MusicFailure.invalidSelection);
    }
    await _select(
      query.accountGeneration,
      query.configEntryId,
      MusicReadService.getLibrary,
    );
    final raw = await api.library(query, isCurrent: () => current);
    _check();
    return parseMusicLibrary(raw, query);
  }

  Future<MusicSearchResults> search(MusicSearchQuery query) async {
    final text = query.text.trim();
    if (query.limit < 1 ||
        query.limit > 100 ||
        text.isEmpty ||
        text.length > 256 ||
        text.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      throw const MusicException(MusicFailure.invalidSelection);
    }
    await _select(
      query.accountGeneration,
      query.configEntryId,
      MusicReadService.search,
    );
    final raw = await api.search(query, isCurrent: () => current);
    _check();
    return parseMusicSearch(raw, query);
  }

  Future<MusicQueueSummary> queue(MusicQueueQuery query) async {
    if (!RegExp(r'^media_player\.[a-z0-9_]+$').hasMatch(query.entityId)) {
      throw const MusicException(MusicFailure.invalidSelection);
    }
    final discovery = await _select(
      query.accountGeneration,
      query.configEntryId,
      MusicReadService.getQueue,
    );
    final registryIssue = discovery.issues[MusicDiscoverySource.registry];
    if (registryIssue != null) throw MusicException(registryIssue);
    final target = discovery.queueTargets
        .where(
          (target) =>
              target.entityId == query.entityId &&
              target.configEntryId == query.configEntryId,
        )
        .firstOrNull;
    if (target == null) {
      throw const MusicException(MusicFailure.invalidSelection);
    }
    if (!target.available || !target.enabled) {
      throw const MusicException(MusicFailure.unavailable);
    }
    final raw = await api.queue(query.entityId, isCurrent: () => current);
    _check();
    return parseMusicQueue(raw, query.entityId);
  }
}

bool _identifier(String value) =>
    value.isNotEmpty &&
    value.length <= 128 &&
    !value.contains(RegExp(r'[\x00-\x20\x7F]'));
MusicFailure classifyMusicFailureFromRegistry(HaMediaInventory inventory) =>
    classifyMusicFailure(HaPlaybackException(inventory.registryFailure!));
