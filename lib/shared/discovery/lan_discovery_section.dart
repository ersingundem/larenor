import 'package:flutter/cupertino.dart';

import 'lan_scanner.dart';

/// A "FOUND ON YOUR NETWORK" list section that sweeps the local subnet for
/// one service via [LanScanner], mirroring the discovery section on the
/// Home Assistant connect screen — drop into any connect screen's
/// `ListView` alongside the manual URL field.
class LanDiscoverySection extends StatefulWidget {
  const LanDiscoverySection({
    super.key,
    required this.signature,
    required this.onSelected,
  });

  final LanServiceSignature signature;
  final ValueChanged<String> onSelected;

  @override
  State<LanDiscoverySection> createState() => _LanDiscoverySectionState();
}

class _LanDiscoverySectionState extends State<LanDiscoverySection> {
  final _scanner = LanScanner();
  final _found = <String>[];
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _scanner.servers.listen((server) {
      if (!mounted) return;
      setState(() => _found.add(server.baseUrl));
    });
    _scanner.scan(widget.signature).whenComplete(() {
      if (mounted) setState(() => _scanning = false);
    });
  }

  @override
  void dispose() {
    _scanner.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_scanning && _found.isEmpty) return const SizedBox.shrink();

    return CupertinoListSection.insetGrouped(
      header: const Text('FOUND ON YOUR NETWORK'),
      children: [
        for (final url in _found)
          CupertinoListTile(
            title: Text(url),
            trailing: const CupertinoListTileChevron(),
            onTap: () => widget.onSelected(url),
          ),
        if (_scanning)
          const CupertinoListTile(
            leading: CupertinoActivityIndicator(),
            title: Text('Scanning…'),
          ),
      ],
    );
  }
}
