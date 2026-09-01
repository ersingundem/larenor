import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../media/prowlarr/presentation/prowlarr_indexers_screen.dart';
import '../../../media/prowlarr/providers/prowlarr_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class ProwlarrTile extends ConsumerWidget {
  const ProwlarrTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(prowlarrConnectionProvider).value != null;
    final indexers = ref.watch(prowlarrIndexersProvider).value ?? const [];
    final enabledCount = indexers.where((i) => i.enabled).length;

    return ServiceTileShell(
      icon: CupertinoIcons.dot_radiowaves_left_right,
      service: AppService.prowlarr,
      title: 'Prowlarr',
      connected: connected,
      onTap: () => Navigator.of(context).push(
        CupertinoPageRoute(builder: (_) => const ProwlarrIndexersScreen()),
      ),
      lines: [
        indexers.isEmpty
            ? AppLocalizations.of(context).prowlarrTileNoIndexers
            : AppLocalizations.of(context)
                  .prowlarrTileEnabledCount(enabledCount, indexers.length),
      ],
    );
  }
}
