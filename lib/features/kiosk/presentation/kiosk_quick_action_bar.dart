import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/settings_section.dart';

/// A closed kiosk navigation surface. The callbacks remain the sole authority
/// for navigation and exit; this widget never constructs a native command.
final class KioskQuickActionBar extends StatefulWidget {
  const KioskQuickActionBar({
    super.key,
    required this.onHome,
    required this.onSettings,
    required this.onExit,
    this.navigationEnabled = true,
    required this.exitEnabled,
  });

  final Future<void> Function() onHome;
  final Future<void> Function() onSettings;
  final Future<void> Function() onExit;
  final bool navigationEnabled;
  final bool exitEnabled;

  @override
  State<KioskQuickActionBar> createState() => _KioskQuickActionBarState();
}

final class _KioskQuickActionBarState extends State<KioskQuickActionBar> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final navigationEnabled = widget.navigationEnabled && !_busy;
    final exitEnabled = widget.exitEnabled && !_busy;
    return SettingsSection(
      header: Semantics(
        container: true,
        header: true,
        child: Text(l.kioskQuickActions),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            alignment: WrapAlignment.center,
            runAlignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _button(
                key: const ValueKey('kiosk-quick-home'),
                label: l.kioskQuickHome,
                enabled: navigationEnabled,
                action: widget.onHome,
              ),
              _button(
                key: const ValueKey('kiosk-quick-settings'),
                label: l.kioskQuickSettings,
                enabled: navigationEnabled,
                action: widget.onSettings,
              ),
              _button(
                key: const ValueKey('kiosk-quick-exit'),
                label: l.kioskQuickExit,
                enabled: exitEnabled,
                action: widget.onExit,
                destructive: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _button({
    required Key key,
    required String label,
    required bool enabled,
    required Future<void> Function() action,
    bool destructive = false,
  }) => Semantics(
    button: true,
    enabled: enabled,
    label: label,
    child: CupertinoButton(
      key: key,
      minimumSize: const Size(48, 48),
      color: destructive ? CupertinoColors.systemRed : null,
      onPressed: enabled ? () => _run(action) : null,
      child: Text(label, textAlign: TextAlign.center),
    ),
  );
}
