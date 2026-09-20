import 'package:flutter/cupertino.dart';

import '../theme/spacing.dart';
import 'service_root_scaffold.dart';
import 'settings_action_tile.dart';
import 'settings_section.dart';

/// Shared full-page state for a service route before its primary content is
/// available. It keeps connection failures private, announces state changes,
/// and exposes an optional tablet-sized recovery action.
class ServiceRouteStatusScaffold extends StatelessWidget {
  const ServiceRouteStatusScaffold({
    super.key,
    required this.title,
    required this.label,
    required this.statusKey,
    this.loading = false,
    this.actionLabel,
    this.actionKey,
    this.onAction,
  }) : assert(
         onAction == null || actionLabel != null && actionKey != null,
         'An action requires both a label and key.',
       );

  final String title;
  final String label;
  final Key statusKey;
  final bool loading;
  final String? actionLabel;
  final Key? actionKey;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => ServiceRootScaffold(
    title: title,
    slivers: [
      SliverToBoxAdapter(
        child: SettingsSection(
          children: [
            Semantics(
              key: statusKey,
              label: label,
              liveRegion: true,
              excludeSemantics: true,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: Gap.huge),
                child: Padding(
                  padding: Insets.tile,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: loading
                        ? const CupertinoActivityIndicator()
                        : Text(label),
                  ),
                ),
              ),
            ),
            if (onAction != null)
              SettingsActionTile(
                buttonKey: actionKey,
                title: Text(actionLabel!),
                onTap: onAction,
              ),
          ],
        ),
      ),
    ],
  );
}
