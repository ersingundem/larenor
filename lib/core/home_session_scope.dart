import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../app.dart';
import 'home_source_store.dart';

final homeSourceStoreProvider = Provider<HomeSourcePersistence>(
  (_) => SharedPreferencesHomeSourceStore(),
);

/// Owns the complete application runtime beneath the device's source choice.
class HomeSessionScope extends StatelessWidget {
  const HomeSessionScope({super.key, this.runtimeOverrides = const []});
  final List<Override> runtimeOverrides;

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: runtimeOverrides,
    child: const LarenorApp(),
  );
}
