import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';

class AppShellScope extends InheritedWidget {
  const AppShellScope({
    super.key,
    required this.hasSidebar,
    required super.child,
  });
  final bool hasSidebar;
  static AppShellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppShellScope>();
  @override
  bool updateShouldNotify(AppShellScope oldWidget) =>
      oldWidget.hasSidebar != hasSidebar;
}

/// The same global entry points on every daily-use root page.
class AppShellActions extends StatelessWidget {
  const AppShellActions({super.key});

  @override
  Widget build(BuildContext context) {
    if (AppShellScope.maybeOf(context)?.hasSidebar == true) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: l10n.navigationSearch,
          child: CupertinoButton(
            key: const ValueKey('global-search'),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onPressed: () => context.push('/search'),
            child: const ExcludeSemantics(child: Icon(CupertinoIcons.search)),
          ),
        ),
        Semantics(
          label: l10n.settingsScreenTitle,
          child: CupertinoButton(
            key: const ValueKey('global-settings'),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            onPressed: () => context.push('/settings'),
            child: const ExcludeSemantics(child: Icon(CupertinoIcons.settings)),
          ),
        ),
      ],
    );
  }
}
