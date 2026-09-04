import 'package:flutter/cupertino.dart';

import '../../../../../shared/theme/spacing.dart';
import '../../../../../shared/theme/typography.dart';
import '../../domain/media_title.dart';
import 'media_poster.dart';

/// One titled horizontal strip of posters.
class MediaRow extends StatelessWidget {
  const MediaRow({
    super.key,
    required this.title,
    required this.titles,
    required this.onTapTitle,
  });

  final String title;
  final List<MediaTitle> titles;
  final ValueChanged<MediaTitle> onTapTitle;

  @override
  Widget build(BuildContext context) {
    if (titles.isEmpty) return const SizedBox.shrink();

    final width = MediaQuery.sizeOf(context).width >= 700 ? 152.0 : 128.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: Insets.sectionHeader,
          child: Text(title, style: AppText.sectionHeader),
        ),
        SizedBox(
          // Derived from the card itself rather than a literal, so the row
          // can't clip its own captions when the text scale changes.
          height: MediaPoster.heightFor(width, context),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: Insets.page,
            itemCount: titles.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = titles[index];
              return MediaPoster(
                title: item,
                width: width,
                onTap: () => onTapTitle(item),
              );
            },
          ),
        ),
      ],
    );
  }
}
