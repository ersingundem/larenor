import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../inventory/data/inventory_scanner.dart';

/// A user-visible, foreground-only QR camera flight. Decoded content stays in
/// memory and is never logged or persisted by this surface.
final class WebPanelQrScanner extends StatefulWidget {
  const WebPanelQrScanner({
    super.key,
    required this.platform,
    required this.isCurrent,
    required this.onAccepted,
    required this.onCancel,
  });

  final InventoryScannerPlatform platform;
  final bool Function() isCurrent;
  final ValueChanged<String> onAccepted;
  final VoidCallback onCancel;

  @override
  State<WebPanelQrScanner> createState() => _WebPanelQrScannerState();
}

class _WebPanelQrScannerState extends State<WebPanelQrScanner> {
  late final InventoryScannerController _scanner;
  late final AppLifecycleListener _lifecycle;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _scanner = InventoryScannerController(
      platform: widget.platform,
      isCurrent: () => mounted && !_finished && widget.isCurrent(),
      onValue: _accept,
    )..addListener(_changed);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        unawaited(_scanner.onLifecycle(state));
        if (state != AppLifecycleState.resumed) _cancel();
      },
    );
    unawaited(_scanner.open());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _accept(String value) {
    if (_finished || !widget.isCurrent() || !_safeValue(value)) {
      _cancel();
      return;
    }
    _finished = true;
    widget.onAccepted(value);
  }

  void _cancel() {
    if (_finished) return;
    _finished = true;
    unawaited(_scanner.close());
    widget.onCancel();
  }

  static bool _safeValue(String value) =>
      value.isNotEmpty &&
      value.length <= 2048 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

  @override
  void dispose() {
    _finished = true;
    _lifecycle.dispose();
    _scanner.removeListener(_changed);
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final failure = _scanner.failure;
    return ColoredBox(
      color: CupertinoColors.systemBackground.resolveFrom(context),
      child: SafeArea(
        child: Semantics(
          key: const ValueKey('web-panel-qr-visible-permission'),
          container: true,
          explicitChildNodes: true,
          label: l10n.webPanelNativeQrVisiblePermission,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  l10n.webPanelNativeQrVisiblePermission,
                  textAlign: TextAlign.center,
                ),
              ),
              Expanded(
                child: failure == null
                    ? (_scanner.preview ?? const SizedBox.shrink())
                    : Center(
                        child: Text(
                          failure == InventoryCameraFailure.permissionDenied
                              ? l10n.inventoryCameraDenied
                              : l10n.inventoryCameraUnavailable,
                          textAlign: TextAlign.center,
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: CupertinoButton(
                  key: const ValueKey('web-panel-qr-cancel'),
                  onPressed: _cancel,
                  child: Text(l10n.inventoryCloseScanner),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
