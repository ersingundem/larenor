import 'package:flutter/cupertino.dart';

import 'app_page_scaffold.dart';

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
  Widget build(BuildContext context) => AppPageScaffold(
    navigationBar: CupertinoNavigationBar(middle: Text(title)),
    child: SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              key: statusKey,
              label: label,
              liveRegion: true,
              excludeSemantics: true,
              child: loading
                  ? const CupertinoActivityIndicator()
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(label, textAlign: TextAlign.center),
                    ),
            ),
            if (onAction != null) ...[
              const SizedBox(height: 12),
              Semantics(
                label: actionLabel,
                child: CupertinoButton(
                  key: actionKey,
                  minimumSize: const Size(48, 48),
                  onPressed: onAction,
                  child: ExcludeSemantics(child: Text(actionLabel!)),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
