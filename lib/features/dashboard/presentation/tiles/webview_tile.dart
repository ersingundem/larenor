import 'package:flutter/widgets.dart';

import '../../../web_panel/domain/web_panel_policy.dart';
import '../../../web_panel/presentation/web_panel_view.dart';
import '../../domain/tile_config.dart';

/// An explicitly configured website; its session owns no HA API credentials.
class WebviewTile extends StatelessWidget {
  const WebviewTile({super.key, required this.tile});
  final TileConfig tile;
  @override
  Widget build(BuildContext context) => WebPanelView(
    policy:
        tile.webPanel?.policyFor(tile.url ?? '') ??
        WebPanelPolicy.fromUrl(tile.url ?? ''),
    sourceIdentity: tile.id,
    options: tile.webPanel,
  );
}
