import 'package:flutter/cupertino.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../domain/tile_config.dart';

/// Renders an arbitrary URL fullscreen inside a tile — e.g. an embedded
/// website, or the raw Home Assistant frontend for panels this app doesn't
/// have a native card for yet.
class WebviewTile extends StatefulWidget {
  const WebviewTile({super.key, required this.tile});

  final TileConfig tile;

  @override
  State<WebviewTile> createState() => _WebviewTileState();
}

class _WebviewTileState extends State<WebviewTile> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(widget.tile.url ?? 'about:blank'));
  }

  @override
  void didUpdateWidget(covariant WebviewTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tile.url != oldWidget.tile.url && widget.tile.url != null) {
      _controller.loadRequest(Uri.parse(widget.tile.url!));
    }
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
