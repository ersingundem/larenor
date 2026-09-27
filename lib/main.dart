import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'core/home_session_scope.dart';
import 'core/configuration_scope.dart';
import 'features/backup/data/backup_repository.dart';
import 'features/multi_display/presentation/secondary_display_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(
    ConfigurationScope(
      initialize: () async {
        await BackupRepository().recoverPendingRestore();
      },
      child: const HomeSessionScope(),
    ),
  );
}

/// Secret-free entry point for one external display owned by Android.
///
/// The secondary engine deliberately does not construct ConfigurationScope or
/// HomeSessionScope. It receives one allow-listed public route identifier and
/// can never inherit account, home, credential, URL, or media metadata state
/// from the primary engine.
@pragma('vm:entry-point')
void dualDisplayMain(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  runSecondaryDisplayApp(arguments);
}
