import 'package:flutter/cupertino.dart';

import 'app_page_scaffold.dart';
import 'operational_service_scope.dart';

import '../theme/spacing.dart';

/// Standard chrome for a service's root screen — Proxmox, Keenetic,
/// Jellyfin and the rest.
///
/// These are list roots reached by drilling in from Settings, and iOS
/// gives drill-down roots a large title (Settings → General shows
/// "General" large). They previously used centred titles purely because
/// of which feature they lived in, so the title treatment collapsed
/// halfway down a navigation stack.
///
/// A large title has to live inside the scroll view to collapse on
/// scroll, which is why this takes slivers rather than a plain child.
class ServiceRootScaffold extends StatelessWidget {
  const ServiceRootScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.leading,
    this.trailing,
  });

  final String title;
  final List<Widget> slivers;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final operationalScope = OperationalServiceScope.maybeOf(context);
    final operational = operationalScope != null;
    return AppPageScaffold(
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(title),
            leading: operational ? null : leading,
            trailing: operational && leading != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [leading!, ?trailing],
                  )
                : trailing,
          ),
          if (operationalScope?.status != null)
            SliverToBoxAdapter(child: operationalScope!.status),
          ...slivers,
          const SliverToBoxAdapter(child: SizedBox(height: Gap.xxxl)),
        ],
      ),
    );
  }
}

/// Wraps a non-scrolling body (a spinner, an error, an empty state) so it
/// fills the remaining space under a large title.
class SliverFilledMessage extends StatelessWidget {
  const SliverFilledMessage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SliverFillRemaining(hasScrollBody: false, child: Center(child: child));
}
