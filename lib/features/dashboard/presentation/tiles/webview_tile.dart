import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/direct_home_access.dart';
import '../../../web_panel/domain/web_panel_policy.dart';
import '../../../web_panel/presentation/web_panel_view.dart';
import '../../domain/tile_config.dart';

/// A Direct-home website reference. Browser login remains separate from HA
/// credentials and the device-shared WebView data store is never cleared here.
class WebviewTile extends ConsumerStatefulWidget {
  const WebviewTile({super.key, required this.tile});
  final TileConfig tile;

  @override
  ConsumerState<WebviewTile> createState() => _WebviewTileState();
}

class _WebviewTileState extends ConsumerState<WebviewTile> {
  // Retain this owner for the whole widget lifetime: a source round trip cannot
  // give an old tile or its native callbacks a newly created Direct capability.
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);

  @override
  Widget build(BuildContext context) {
    ref.watch(directHomeAccessProvider);
    if (!_access.isCurrent) return const SizedBox.shrink();
    final tile = widget.tile;
    return WebPanelView(
      policy:
          tile.webPanel?.policyFor(tile.url ?? '') ??
          WebPanelPolicy.fromUrl(tile.url ?? ''),
      sourceIdentity: (_access, tile.id),
      sourceCurrent: () => _access.isCurrent,
      options: tile.webPanel,
    );
  }
}
