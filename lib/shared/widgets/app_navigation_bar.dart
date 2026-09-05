import 'package:flutter/cupertino.dart';

import '../theme/app_colors.dart';
import '../theme/typography.dart';

/// Compact tablet/DeX navigation, with the same keyboard controls as the sidebar.
/// The four labels determine the height; system text scaling is never clamped.
class AppNavigationBar extends StatelessWidget {
  const AppNavigationBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  }) : assert(items.length >= 2),
       assert(currentIndex >= 0 && currentIndex < items.length);

  final List<BottomNavigationBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.navigation.resolveFrom(context),
      border: Border(
        top: BorderSide(
          color: CupertinoColors.separator.resolveFrom(context),
          width: 0.5,
        ),
      ),
    ),
    child: SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: FocusTraversalGroup(
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Semantics(
                      selected: i == currentIndex,
                      label: items[i].semanticsLabel ?? items[i].label,
                      hint: CupertinoLocalizations.of(context)
                          .tabSemanticsLabel(
                            tabIndex: i + 1,
                            tabCount: items.length,
                          ),
                      child: CupertinoButton(
                        key: ValueKey('root-navigation-$i'),
                        minimumSize: const Size(48, 48),
                        focusColor: CupertinoTheme.of(context).primaryColor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        borderRadius: BorderRadius.circular(14),
                        color: i == currentIndex
                            ? AppColors.surface.resolveFrom(context)
                            : null,
                        onPressed: () => onTap(i),
                        child: ExcludeSemantics(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconTheme.merge(
                                data: IconThemeData(
                                  size: 24,
                                  color: i == currentIndex
                                      ? CupertinoTheme.of(context).primaryColor
                                      : CupertinoColors.secondaryLabel
                                            .resolveFrom(context),
                                ),
                                child: i == currentIndex
                                    ? items[i].activeIcon
                                    : items[i].icon,
                              ),
                              if (items[i].label case final label?) ...[
                                const SizedBox(height: 4),
                                Text(
                                  label,
                                  textAlign: TextAlign.center,
                                  style: AppText.caption1.copyWith(
                                    color: CupertinoColors.label.resolveFrom(
                                      context,
                                    ),
                                    fontWeight: i == currentIndex
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
