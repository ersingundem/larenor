import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../media/arr/presentation/readarr_screen.dart';
import '../../../media/arr/providers/readarr_providers.dart';
import '../../domain/tile_config.dart';
import 'service_tile_shell.dart';
import '../../../settings/data/app_service.dart';

class ReadarrTile extends ConsumerWidget {
  const ReadarrTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(readarrConnectionProvider).value != null;
    final items = ref.watch(readarrCalendarProvider).value ?? const [];

    return ServiceTileShell(
      icon: CupertinoIcons.book,
      service: AppService.readarr,
      title: 'Readarr',
      connected: connected,
      onTap: () =>
          Navigator.of(context)
              .push(CupertinoPageRoute(builder: (_) => const ReadarrScreen())),
      lines: items.isEmpty
          ? [AppLocalizations.of(context).commonNothingUpcoming]
          : items.take(3).map((item) => item.title).toList(),
    );
  }
}
