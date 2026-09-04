import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../data/models/bazarr_wanted_item.dart';
import '../providers/bazarr_providers.dart';
import 'bazarr_connect_screen.dart';
import '../../../../shared/widgets/service_root_scaffold.dart';
import '../../../../shared/theme/spacing.dart';
import '../../../../shared/widgets/settings_section.dart';

class BazarrHomeScreen extends ConsumerWidget {
  const BazarrHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(bazarrConnectionProvider);

    return connectionAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text(error.toString()))),
      data: (config) {
        if (config == null) return const BazarrConnectScreen();
        return const _BazarrWantedScaffold();
      },
    );
  }
}

class _BazarrWantedScaffold extends ConsumerWidget {
  const _BazarrWantedScaffold();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final moviesAsync = ref.watch(bazarrMissingMoviesProvider);
    final episodesAsync = ref.watch(bazarrMissingEpisodesProvider);

    void refresh() {
      ref.invalidate(bazarrMissingMoviesProvider);
      ref.invalidate(bazarrMissingEpisodesProvider);
    }

    return ServiceRootScaffold(
      title: 'Bazarr',
      trailing: CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: refresh,
        child: const Icon(CupertinoIcons.refresh),
      ),
      slivers: [
        SliverList(
          delegate: SliverChildListDelegate([
            const SizedBox(height: Gap.sm),
            _WantedSection(
              title: AppLocalizations.of(context).bazarrMoviesMissingHeader,
              itemsAsync: moviesAsync,
              onChanged: refresh,
            ),
            _WantedSection(
              title: AppLocalizations.of(context).bazarrEpisodesMissingHeader,
              itemsAsync: episodesAsync,
              onChanged: refresh,
            ),
          ]),
        ),
      ],
    );
  }
}

class _WantedSection extends ConsumerWidget {
  const _WantedSection({
    required this.title,
    required this.itemsAsync,
    required this.onChanged,
  });

  final String title;
  final AsyncValue<List<BazarrWantedItem>> itemsAsync;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return itemsAsync.when(
      loading: () => const Center(child: CupertinoActivityIndicator()),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          AppLocalizations.of(context)
              .bazarrLoadSectionError(title, error.toString()),
        ),
      ),
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return SettingsSection(
          header: Text(title),
          children: [
            for (final item in items)
              _WantedRow(item: item, onChanged: onChanged),
          ],
        );
      },
    );
  }
}

class _WantedRow extends ConsumerStatefulWidget {
  const _WantedRow({required this.item, required this.onChanged});

  final BazarrWantedItem item;
  final VoidCallback onChanged;

  @override
  ConsumerState<_WantedRow> createState() => _WantedRowState();
}

class _WantedRowState extends ConsumerState<_WantedRow> {
  bool _searching = false;

  Future<void> _searchFirstMissing() async {
    final client = ref.read(bazarrClientProvider);
    final language = widget.item.missingLanguages.firstOrNull;
    if (client == null || language == null) return;

    setState(() => _searching = true);
    try {
      if (widget.item.isMovie) {
        await client.searchMovieSubtitle(
          radarrId: widget.item.radarrId!,
          language: language.code,
        );
      } else if (widget.item.seriesId != null &&
          widget.item.episodeId != null) {
        await client.searchEpisodeSubtitle(
          seriesId: widget.item.seriesId!,
          episodeId: widget.item.episodeId!,
          language: language.code,
        );
      }
      widget.onChanged();
    } catch (_) {
      // Row simply won't update; user can retry.
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final languages = widget.item.missingLanguages
        .map((l) => l.label)
        .join(', ');

    return CupertinoListTile(
      leading: const Icon(CupertinoIcons.captions_bubble),
      title: Text(widget.item.title),
      subtitle: Text(
        languages.isEmpty
            ? AppLocalizations.of(context).bazarrMissingSubtitlesLabel
            : languages,
      ),
      trailing: _searching
          ? const CupertinoActivityIndicator()
          : CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: widget.item.missingLanguages.isEmpty
                  ? null
                  : _searchFirstMissing,
              child: Text(AppLocalizations.of(context).commonSearch),
            ),
    );
  }
}
