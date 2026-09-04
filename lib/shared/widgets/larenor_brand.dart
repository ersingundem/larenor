import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;

import '../theme/typography.dart';

/// The same emblem is used in the app and by the operating-system launcher.
/// The wordmark and motto remain text, so neither becomes tiny baked-in artwork.
class LarenorLogo extends StatelessWidget {
  const LarenorLogo({super.key, this.size = 48});

  final double size;
  static const asset = 'assets/icon/app_icon.png';

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Larenor',
    image: true,
    child: ClipPath(
      clipper: ShapeBorderClipper(
        shape: ContinuousRectangleBorder(
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
      ),
      child: Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        filterQuality: FilterQuality.medium,
      ),
    ),
  );
}

class LarenorBrand extends StatelessWidget {
  const LarenorBrand({super.key, this.compact = false, this.centered = false});

  final bool compact;
  final bool centered;

  static const motto = 'Unus Lar, omnem domum servat.';

  @override
  Widget build(BuildContext context) {
    final logoSize = compact ? 42.0 : 80.0;
    final wordmarkStyle = (compact ? AppText.title2 : AppText.largeTitle)
        .copyWith(
          letterSpacing: -0.6,
          color: CupertinoColors.label.resolveFrom(context),
        );
    final mottoStyle = AppText.footnote.copyWith(
      color: CupertinoColors.secondaryLabel.resolveFrom(context),
      fontStyle: FontStyle.italic,
      height: 1.5,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final minRowWidth =
            logoSize +
            14 +
            MediaQuery.textScalerOf(context).scale(wordmarkStyle.fontSize!) *
                4.3;
        final stacked = centered || constraints.maxWidth < minRowWidth;
        final alignment = centered
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start;
        final logo = ExcludeSemantics(child: LarenorLogo(size: logoSize));
        final wordmark = Text('Larenor', style: wordmarkStyle);
        return Column(
          crossAxisAlignment: alignment,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (stacked) ...[
              logo,
              SizedBox(height: compact ? 10 : 16),
              wordmark,
            ] else
              Row(
                children: [
                  logo,
                  const SizedBox(width: 14),
                  Expanded(child: wordmark),
                ],
              ),
            SizedBox(height: compact ? 8 : 10),
            SelectableText(
              motto,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: mottoStyle,
            ),
          ],
        );
      },
    );
  }
}
