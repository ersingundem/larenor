import '../../media_catalog/domain/server_media_catalog_models.dart';
import '../../offline_media/domain/server_offline_media_models.dart';

/// The exact Core catalog observation that is allowed to supply local bytes.
///
/// It deliberately carries no provider address or credential. A source must
/// prove that its authority still matches every field before exposing a URI to
/// the native player.
final class CoreCatalogPlayerBinding {
  const CoreCatalogPlayerBinding._({
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    required this.jellyfinServiceRevision,
    required this.itemId,
    required this.mediaKey,
    required this.title,
    required this.kind,
    required this.runtimeSeconds,
  });

  factory CoreCatalogPlayerBinding.fromCatalog(
    ServerMediaCatalogPage page,
    ServerMediaCatalogItem item,
  ) {
    if (!page.items.any(
      (candidate) =>
          identical(candidate, item) ||
          candidate.itemId == item.itemId &&
              candidate.mediaKey == item.mediaKey &&
              candidate.kind == item.kind,
    )) {
      throw const FormatException('catalog_item_not_in_page');
    }
    return CoreCatalogPlayerBinding._(
      installationId: page.installationId,
      installationRevision: page.installationRevision,
      snapshotRevision: page.snapshotRevision,
      jellyfinServiceRevision: page.jellyfinServiceRevision,
      itemId: item.itemId,
      mediaKey: item.mediaKey,
      title: item.title,
      kind: item.kind,
      runtimeSeconds: item.runtimeSeconds,
    );
  }

  final String installationId, itemId, mediaKey, title;
  final int installationRevision, snapshotRevision, jellyfinServiceRevision;
  final ServerMediaCatalogKind kind;
  final int? runtimeSeconds;

  bool acceptsOfflineManifest(ServerOfflineMediaManifest manifest) =>
      manifest.complete &&
      manifest.installationId == installationId &&
      manifest.installationRevision == installationRevision &&
      manifest.snapshotRevision == snapshotRevision &&
      manifest.jellyfinServiceRevision == jellyfinServiceRevision &&
      manifest.itemId == itemId &&
      manifest.mediaKey == mediaKey &&
      manifest.title == title;
}
