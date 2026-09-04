import 'package:flutter/cupertino.dart';

import '../theme/app_colors.dart';

class AppSurface extends StatelessWidget {
  const AppSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          AppColors.canvas.resolveFrom(context),
          AppColors.mist.resolveFrom(context),
          AppColors.dusk.resolveFrom(context),
        ],
      ),
    ),
    child: child,
  );
}

/// Shared adaptive page background; scrolling navigation bars stay native.
class AppPageScaffold extends StatelessWidget {
  const AppPageScaffold({super.key, required this.child, this.navigationBar});
  final Widget child;
  final ObstructingPreferredSizeWidget? navigationBar;
  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    backgroundColor: AppColors.canvas.resolveFrom(context),
    navigationBar: navigationBar,
    child: AppSurface(child: child),
  );
}
