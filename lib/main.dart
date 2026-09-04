import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/configuration_scope.dart';
import 'features/backup/data/backup_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // This is a wall-panel/kiosk app (it registers for the Android HOME
  // role) — it should always run fullscreen, not just when set as the
  // default launcher. `immersiveSticky` hides the status and navigation
  // bars but still lets an edge swipe reveal them briefly (e.g. to pull
  // down notifications), auto-hiding again afterwards.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(
    ConfigurationScope(
      initialize: () async {
        await BackupRepository().recoverPendingRestore();
      },
      child: const LarenorApp(),
    ),
  );
}
