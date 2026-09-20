import 'package:flutter/cupertino.dart';

import 'settings_action_tile.dart';

/// A settings service row with two explicit actions: open and enable/disable.
///
/// Keeping the navigation button and switch as siblings avoids nested tap
/// semantics while preserving a predictable Tab order for tablet keyboards.
class SettingsServiceTile extends StatelessWidget {
  const SettingsServiceTile({
    super.key,
    required this.title,
    required this.leading,
    required this.additionalInfo,
    required this.enabled,
    required this.onOpen,
    required this.onToggle,
    this.openKey,
    this.toggleKey,
    this.busy = false,
  });

  final String title;
  final Widget leading;
  final Widget additionalInfo;
  final bool enabled;
  final VoidCallback? onOpen;
  final ValueChanged<bool>? onToggle;
  final Key? openKey;
  final Key? toggleKey;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: SettingsActionTile(
              buttonKey: openKey,
              leading: leading,
              title: Text(title),
              additionalInfo: additionalInfo,
              onTap: onOpen,
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: busy
                ? const SizedBox(
                    width: 60,
                    height: 48,
                    child: Center(child: CupertinoActivityIndicator()),
                  )
                : Semantics(
                    key: toggleKey,
                    container: true,
                    label: title,
                    toggled: enabled,
                    enabled: onToggle != null,
                    onTap: onToggle == null ? null : () => onToggle!(!enabled),
                    child: SizedBox(
                      width: 60,
                      height: 48,
                      child: Center(
                        child: ExcludeSemantics(
                          child: CupertinoSwitch(
                            value: enabled,
                            onChanged: onToggle,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
