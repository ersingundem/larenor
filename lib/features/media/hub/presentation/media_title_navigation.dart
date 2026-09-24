import 'package:flutter/cupertino.dart';

import '../domain/media_title.dart';
import 'media_title_detail_screen.dart';

void openMediaTitle(BuildContext context, MediaTitle title) {
  Navigator.of(context).push(
    CupertinoPageRoute(builder: (_) => MediaTitleDetailScreen(title: title)),
  );
}
