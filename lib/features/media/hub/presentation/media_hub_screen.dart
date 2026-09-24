import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/home_session_controller.dart';
import '../../../../core/home_source_store.dart';
import '../../../server/media_catalog/presentation/server_media_catalog_screen.dart';
import 'direct_media_hub_screen.dart';

/// Selects the authority-safe media surface for the current home.
///
/// Recovery, failed source reads and verified Core homes stay on the Larenor
/// Core contract. Device-local provider clients are reachable only after an
/// exact [HomeSource.directLocal] proof.
class MediaHubScreen extends ConsumerWidget {
  const MediaHubScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeSessionControllerProvider);
    if (home == null || home.source != HomeSource.directLocal) {
      return const ServerMediaCatalogScreen(showAccountRows: true);
    }
    return DirectMediaHubScreen(embedded: embedded);
  }
}
