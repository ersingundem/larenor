import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme.dart';
import 'features/settings/presentation/idle_gate.dart';
import 'features/settings/presentation/screen_policy_runner.dart';
import 'l10n/generated/app_localizations.dart';

class LarenorApp extends ConsumerWidget {
  const LarenorApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return CupertinoApp.router(
      title: 'Larenor',
      debugShowCheckedModeBanner: false,
      theme: larenorCupertinoTheme,
      // No `locale:` override — this follows the device's own language
      // setting automatically, falling back to English (the first
      // supportedLocales entry) for any language not in the list.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      builder: (context, child) => ScreenPolicyRunner(
        child: IdleGate(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
