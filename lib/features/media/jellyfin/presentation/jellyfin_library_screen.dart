import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../hub/presentation/media_session_state.dart';
import '../providers/jellyfin_providers.dart';
import 'jellyfin_item_detail_screen.dart';
import 'widgets/jellyfin_poster.dart';

/// Shows the contents of a Jellyfin library or folder. Tapping a playable
/// item (Movie/Episode) or a container (Series/Season/folder) both push
/// [JellyfinItemDetailScreen], which then either offers Play or a further
/// "Browse" step into this same screen — a simple recursive drill-down.
class JellyfinLibraryScreen extends ConsumerStatefulWidget {
  const JellyfinLibraryScreen({
    super.key,
    required this.parentId,
    required this.title,
  });

  final String parentId;
  final String title;

  @override
  ConsumerState<JellyfinLibraryScreen> createState() =>
      _JellyfinLibraryScreenState();
}

class _JellyfinLibraryScreenState
    extends MediaSessionState<JellyfinLibraryScreen> {
  bool _current(int generation, Object reading) =>
      sessionCurrent(generation) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true &&
      identical(
        ref.read(jellyfinLibraryItemsProvider(widget.parentId)),
        reading,
      );

  @override
  Widget build(BuildContext context) {
    final provider = jellyfinLibraryItemsProvider(widget.parentId);
    final itemsAsync = ref.watch(provider);
    final generation = sessionGeneration;
    final active = _current(generation, itemsAsync);

    return ServiceRootScaffold(
      title: widget.title,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('jellyfin-library-header'),
              header: true,
              child: Text(widget.title),
            ),
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('jellyfin-library-refresh'),
                title: Text(AppLocalizations.of(context).commonRefresh),
                onTap: active
                    ? () {
                        if (_current(generation, itemsAsync)) {
                          ref.invalidate(provider);
                        }
                      }
                    : null,
              ),
            ],
          ),
        ),
        itemsAsync.when(
          loading: () => SliverFilledMessage(
            child: _LibraryStatus(
              label: AppLocalizations.of(context).commonLoading,
              loading: true,
            ),
          ),
          error: (_, _) => SliverFilledMessage(
            child: _LibraryStatus(
              label: AppLocalizations.of(context).mediaErrorUnreachable,
            ),
          ),
          data: (items) {
            if (items.isEmpty) {
              return SliverFilledMessage(
                child: _LibraryStatus(
                  label: AppLocalizations.of(context).jellyfinLibraryEmpty,
                ),
              );
            }
            return SliverLayoutBuilder(
              builder: (context, constraints) {
                const spacing = 12.0;
                const maxWidth = 140.0;
                final usableWidth = constraints.crossAxisExtent - spacing * 2;
                final columns = math.max(
                  1,
                  (usableWidth / (maxWidth + spacing)).ceil(),
                );
                final posterWidth =
                    (usableWidth - spacing * (columns - 1)) / columns;
                return SliverPadding(
                  padding: const EdgeInsets.all(12),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: spacing,
                      crossAxisSpacing: spacing,
                      mainAxisExtent: JellyfinPoster.heightFor(
                        posterWidth,
                        context,
                      ),
                    ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final item = items[index];
                      return JellyfinPoster(
                        item: item,
                        width: double.infinity,
                        onTap: () {
                          if (!_current(generation, itemsAsync)) return;
                          Navigator.of(context).push(
                            CupertinoPageRoute(
                              builder: (_) =>
                                  JellyfinItemDetailScreen(item: item),
                            ),
                          );
                        },
                      );
                    }, childCount: items.length),
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

/// The browse flow uses the same private, live status contract as the media
/// hub: backend diagnostics stay out of the UI and TalkBack gets one update.
class _LibraryStatus extends StatelessWidget {
  const _LibraryStatus({required this.label, this.loading = false});

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      key: const ValueKey('jellyfin-library-status'),
      label: label,
      liveRegion: true,
      excludeSemantics: true,
      child: loading
          ? const CupertinoActivityIndicator()
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Text(label, textAlign: TextAlign.center),
            ),
    ),
  );
}
