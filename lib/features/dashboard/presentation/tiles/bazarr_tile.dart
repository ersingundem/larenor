import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../media/bazarr/presentation/bazarr_home_screen.dart';
import '../../../media/bazarr/providers/bazarr_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class BazarrTile extends ConsumerWidget {
  const BazarrTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(bazarrConnectionProvider).value != null;
    final movies = ref.watch(bazarrMissingMoviesProvider).value ?? const [];
    final episodes = ref.watch(bazarrMissingEpisodesProvider).value ?? const [];
    final missingCount = movies.length + episodes.length;

    return ServiceTileShell(
      icon: CupertinoIcons.captions_bubble,
      service: AppService.bazarr,
      title: 'Bazarr',
      connected: connected,
      onTap: () => Navigator.of(context)
          .push(CupertinoPageRoute(builder: (_) => const BazarrHomeScreen())),
      lines: [
        missingCount == 0
            ? 'No missing subtitles'
            : '$missingCount missing subtitles',
      ],
    );
  }
}
