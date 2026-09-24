import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../media_result_origin.dart';
import '../data/server_media_rows_controller.dart';
import '../domain/server_media_rows_models.dart';

final class ServerMediaRowsSection extends StatelessWidget {
  const ServerMediaRowsSection({
    super.key,
    required this.controller,
    required this.active,
    required this.onRetry,
    required this.onOpen,
  });

  final ServerMediaRowsController controller;
  final bool active;
  final VoidCallback onRetry;
  final ValueChanged<ServerMediaRowItem> onOpen;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final value = controller.value;
      if (value == null && controller.busy) {
        return Semantics(
          key: const ValueKey('server-media-rows-loading'),
          liveRegion: true,
          child: const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CupertinoActivityIndicator()),
          ),
        );
      }
      if (value == null && controller.failure != null) {
        return Semantics(
          key: const ValueKey('server-media-rows-error'),
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${l.commonError} ${l.serverMediaCacheUnavailable}',
                    style: AppText.body,
                  ),
                ),
                const SizedBox(width: 12),
                CupertinoButton.filled(
                  key: const ValueKey('server-media-rows-retry'),
                  minimumSize: const Size(48, 48),
                  onPressed: active ? onRetry : null,
                  child: Text(l.commonRetry),
                ),
              ],
            ),
          ),
        );
      }
      if (value == null) return const SizedBox.shrink();
      return Semantics(
        key: const ValueKey('server-media-rows-section'),
        container: true,
        explicitChildNodes: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      controller.origin == ServerMediaResultOrigin.verifiedCache
                          ? l.serverMediaCacheVerified
                          : l.serverMediaCacheLive,
                      style: AppText.footnote,
                    ),
                  ),
                  if (controller.busy)
                    const CupertinoActivityIndicator(radius: 8),
                ],
              ),
            ),
            _Lane(
              key: const ValueKey('server-media-rows-resume'),
              title: l.mediaRowContinueWatching,
              items: value.rows.resume,
              showProgress: true,
              emptyLabel: l.mediaSearchEmpty,
              active: active,
              resolvingItemId: controller.resolvingItemId,
              onOpen: onOpen,
            ),
            _Lane(
              key: const ValueKey('server-media-rows-recent'),
              title: l.mediaRowRecentlyAdded,
              items: value.rows.recent,
              showProgress: false,
              emptyLabel: l.mediaSearchEmpty,
              active: active,
              resolvingItemId: controller.resolvingItemId,
              onOpen: onOpen,
            ),
            if (controller.resolutionFailure != null)
              Semantics(
                key: const ValueKey('server-media-row-resolution-error'),
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    '${l.commonError} ${l.serverMediaCacheUnavailable}',
                    style: AppText.footnote,
                  ),
                ),
              ),
            if (controller.failure != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '${l.commonError} ${l.serverMediaCacheUnavailable}',
                  style: AppText.footnote,
                ),
              ),
          ],
        ),
      );
    },
  );
}

final class _Lane extends StatelessWidget {
  const _Lane({
    super.key,
    required this.title,
    required this.items,
    required this.showProgress,
    required this.emptyLabel,
    required this.active,
    required this.resolvingItemId,
    required this.onOpen,
  });

  final String title, emptyLabel;
  final List<ServerMediaRowItem> items;
  final bool showProgress;
  final bool active;
  final String? resolvingItemId;
  final ValueChanged<ServerMediaRowItem> onOpen;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final cardHeight = 190.0 + ((scale - 1).clamp(0, 2) * 50);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(title, style: AppText.title3),
          ),
          const SizedBox(height: 10),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(emptyLabel, style: AppText.body),
            )
          else
            SizedBox(
              height: cardHeight,
              child: ListView.separated(
                key: ValueKey('${key.toString()}-list'),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) => _RowCard(
                  item: items[index],
                  showProgress: showProgress,
                  active: active && resolvingItemId == null,
                  resolving: resolvingItemId == items[index].itemId,
                  onOpen: onOpen,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final class _RowCard extends StatelessWidget {
  const _RowCard({
    required this.item,
    required this.showProgress,
    required this.active,
    required this.resolving,
    required this.onOpen,
  });

  final ServerMediaRowItem item;
  final bool showProgress;
  final bool active, resolving;
  final ValueChanged<ServerMediaRowItem> onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final kind = item.kind == ServerMediaRowKind.movie
        ? l.mediaKindMovie
        : l.mediaEpisodesTitle;
    final percent = (item.progress * 100).round();
    return Semantics(
      key: ValueKey('server-media-row-${item.itemId}'),
      label: '${item.title}, $kind',
      value: showProgress ? '$percent%' : null,
      button: true,
      child: ExcludeSemantics(
        child: CupertinoButton(
          minimumSize: const Size(48, 48),
          padding: EdgeInsets.zero,
          onPressed: active ? () => onOpen(item) : null,
          child: Container(
            width: 220,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: CupertinoDynamicColor.resolve(
                CupertinoColors.secondarySystemGroupedBackground,
                context,
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: CupertinoDynamicColor.resolve(
                  CupertinoColors.separator,
                  context,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (resolving)
                  const CupertinoActivityIndicator(radius: 13)
                else
                  Icon(
                    item.kind == ServerMediaRowKind.movie
                        ? CupertinoIcons.film
                        : CupertinoIcons.tv,
                    size: 26,
                  ),
                const SizedBox(height: 12),
                Text(
                  item.title,
                  style: AppText.headline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const Spacer(),
                Text(kind, style: AppText.footnote),
                if (showProgress) ...[
                  const SizedBox(height: 10),
                  Container(
                    height: 5,
                    decoration: BoxDecoration(
                      color: CupertinoDynamicColor.resolve(
                        CupertinoColors.systemGrey4,
                        context,
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    clipBehavior: Clip.antiAlias,
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: item.progress,
                      child: Container(color: CupertinoColors.activeBlue),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
