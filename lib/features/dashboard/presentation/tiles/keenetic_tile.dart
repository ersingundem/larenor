import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../keenetic/presentation/keenetic_home_screen.dart';
import '../../../keenetic/providers/keenetic_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class KeeneticTile extends ConsumerWidget {
  const KeeneticTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(keeneticConnectionProvider).value != null;
    final devices = ref.watch(keeneticDevicesProvider).value ?? const [];
    final activeCount = devices.where((d) => d.active).length;
    final aps = ref.watch(keeneticAccessPointsProvider).value ?? const [];
    final apsUp = aps.where((a) => a.up).length;

    return ServiceTileShell(
      icon: CupertinoIcons.wifi,
      service: AppService.keenetic,
      title: 'Keenetic',
      connected: connected,
      onTap: () => Navigator.of(context)
          .push(CupertinoPageRoute(builder: (_) => const KeeneticHomeScreen())),
      lines: [
        AppLocalizations.of(context).keeneticTileDevicesOnline(activeCount),
        if (aps.isNotEmpty)
          AppLocalizations.of(context).keeneticTileWifiUp(apsUp, aps.length),
      ],
    );
  }
}
