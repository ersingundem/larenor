import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../media/arr/presentation/lidarr_screen.dart';
import '../../../media/arr/providers/lidarr_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class LidarrTile extends ConsumerWidget {
  const LidarrTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(lidarrConnectionProvider).value != null;
    final items = ref.watch(lidarrCalendarProvider).value ?? const [];

    return ServiceTileShell(
      icon: CupertinoIcons.music_note,
      service: AppService.lidarr,
      title: 'Lidarr',
      connected: connected,
      onTap: () =>
          Navigator.of(context)
              .push(CupertinoPageRoute(builder: (_) => const LidarrScreen())),
      lines: items.isEmpty
          ? [AppLocalizations.of(context).commonNothingUpcoming]
          : items.take(3).map((item) => item.title).toList(),
    );
  }
}
