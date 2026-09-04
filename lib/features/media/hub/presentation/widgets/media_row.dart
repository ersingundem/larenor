import 'package:flutter/cupertino.dart';

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
          child: Text(
            title,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(
          height: 232,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: titles.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = titles[index];
              return MediaPoster(title: item, onTap: () => onTapTitle(item));
            },
          ),
        ),
      ],
    );
  }
}
