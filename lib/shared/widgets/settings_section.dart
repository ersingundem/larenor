import 'package:flutter/cupertino.dart';

import '../theme/typography.dart';

/// A grouped list section with iOS's real header and footer type.
///
/// Flutter's `CupertinoListSection.insetGrouped` hardcodes its header at
/// 20pt bold (`list_section.dart`) and leaves the footer at the theme's
/// body size. Real iOS Settings uses 13pt secondary grey for both, so the
/// stock widget renders headers far too heavy and footers far too large
/// beside 17pt row titles — which is exactly how these screens looked.
///
/// A drop-in replacement: same API, same insets, dividers and corners.
/// Only the two text styles that are wrong get overridden. Those styles
/// sit *inside* Flutter's own, so the innermost one wins for the text.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.children,
    this.header,
    this.footer,
    this.margin,
  });

  final Widget? header;
  final Widget? footer;
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final style = AppText.footnote.copyWith(
      color: CupertinoColors.secondaryLabel.resolveFrom(context),
    );

    return CupertinoListSection.insetGrouped(
      margin: margin,
      header: header == null
          ? null
          : DefaultTextStyle(style: style, child: header!),
      footer: footer == null
          ? null
          : DefaultTextStyle(style: style, child: footer!),
      children: children,
    );
  }
}
