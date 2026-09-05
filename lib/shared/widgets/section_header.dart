import 'package:flutter/cupertino.dart';

import '../theme/spacing.dart';
import '../theme/typography.dart';

/// The heading above a section of content.
///
/// There were previously five different treatments for this one role —
/// 20pt bold, 19pt bold, 12pt regular, 12pt uppercased, and a 12pt variant
/// with an unresolved colour — and the headings were inset 20pt while the
/// content they labelled was inset 16pt, so every title sat visibly
/// misaligned with its own first tile.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;

  /// An optional action on the trailing edge, e.g. "See all".
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Semantics(
      header: true,
      child: Text(
        title,
        style: AppText.sectionHeader.copyWith(
          color: CupertinoColors.label.resolveFrom(context),
        ),
      ),
    );

    return Padding(
      padding: Insets.sectionHeader,
      child: trailing == null
          ? text
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(child: text),
                trailing!,
              ],
            ),
    );
  }
}

/// A sliver-wrapped [SectionHeader], for the `CustomScrollView`s that make
/// up the dashboard and media hub.
class SliverSectionHeader extends StatelessWidget {
  const SliverSectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: SectionHeader(title: title, trailing: trailing),
  );
}
