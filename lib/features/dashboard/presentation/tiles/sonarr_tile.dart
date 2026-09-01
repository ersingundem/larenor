import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../media/arr/presentation/sonarr_screen.dart';
import '../../../media/arr/providers/sonarr_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class SonarrTile extends ConsumerWidget {
  const SonarrTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(sonarrConnectionProvider).value != null;
    final items = ref.watch(sonarrCalendarProvider).value ?? const [];

    return ServiceTileShell(
      icon: CupertinoIcons.tv,
      service: AppService.sonarr,
      title: 'Sonarr',
      connected: connected,
      onTap: () =>
          Navigator.of(context)
              .push(CupertinoPageRoute(builder: (_) => const SonarrScreen())),
      lines: items.isEmpty
          ? const ['Nothing upcoming']
          : items.take(3).map((item) => item.title).toList(),
    );
  }
}
