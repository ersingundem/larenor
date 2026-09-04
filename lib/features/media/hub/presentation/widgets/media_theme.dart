import 'package:flutter/cupertino.dart';

import '../../../../../shared/theme/typography.dart';

/// Media inherits the same appearance, accent and typography as the home.
/// Dark overlays belong only to artwork, where they keep text legible.
class MediaTheme extends StatelessWidget {
  const MediaTheme({super.key, required this.builder});
  final WidgetBuilder builder;
  @override
  Widget build(BuildContext context) => DefaultTextStyle(
    style: CupertinoTheme.of(context).textTheme.textStyle
        .copyWith(fontFamily: AppText.fontFamily),
    child: builder(context),
  );
}
