import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../media/arr/presentation/radarr_screen.dart';
import '../../../media/arr/providers/radarr_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class RadarrTile extends ConsumerWidget {
  const RadarrTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(radarrConnectionProvider).value != null;
    final items = ref.watch(radarrCalendarProvider).value ?? const [];

    return ServiceTileShell(
      icon: CupertinoIcons.film,
      service: AppService.radarr,
      title: 'Radarr',
      connected: connected,
      onTap: () =>
          Navigator.of(context)
              .push(CupertinoPageRoute(builder: (_) => const RadarrScreen())),
      lines: items.isEmpty
          ? const ['Nothing upcoming']
          : items.take(3).map((item) => item.title).toList(),
    );
  }
}
