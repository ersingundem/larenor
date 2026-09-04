import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/generated/app_localizations.dart';

/// Daily-use service pages may operate a saved connection, but account changes
/// belong to the Settings route, which applies the user's PIN policy.
class OperationalServiceScope extends InheritedWidget {
  const OperationalServiceScope({super.key, required super.child, this.status});

  final Widget? status;

  static OperationalServiceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OperationalServiceScope>();

  static bool isOperational(BuildContext context) => maybeOf(context) != null;

  @override
  bool updateShouldNotify(OperationalServiceScope oldWidget) =>
      status != oldWidget.status;
}

class ServiceAccountAction extends StatelessWidget {
  const ServiceAccountAction({super.key, required this.onSignOut});

  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final operational = OperationalServiceScope.isOperational(context);
    final l10n = AppLocalizations.of(context);
    return CupertinoButton(
      key: const ValueKey('service-account-action'),
      padding: EdgeInsets.zero,
      onPressed: operational ? () => context.push('/settings') : onSignOut,
      child: Icon(
        operational
            ? CupertinoIcons.settings
            : CupertinoIcons.square_arrow_right,
        semanticLabel: operational
            ? l10n.settingsScreenTitle
            : l10n.commonSignOut,
      ),
    );
  }
}
