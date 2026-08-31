import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/camera_snapshot.dart';

class CameraViewerScreen extends StatelessWidget {
  const CameraViewerScreen({
    super.key,
    required this.entityId,
    required this.title,
  });

  final String entityId;
  final String title;

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(title)),
      child: SafeArea(
        child: CameraSnapshot(
          entityId: entityId,
          refreshInterval: const Duration(seconds: 2),
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
