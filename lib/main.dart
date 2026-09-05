import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/configuration_scope.dart';
import 'features/backup/data/backup_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(
    ConfigurationScope(
      initialize: () async {
        await BackupRepository().recoverPendingRestore();
      },
      child: const LarenorApp(),
    ),
  );
}
