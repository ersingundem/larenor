import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme.dart';
import 'features/settings/presentation/idle_gate.dart';
import 'features/settings/presentation/screen_policy_runner.dart';

class OikosApp extends ConsumerWidget {
  const OikosApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return CupertinoApp.router(
      title: 'Oikos',
      debugShowCheckedModeBanner: false,
      theme: oikosCupertinoTheme,
      routerConfig: router,
      builder: (context, child) => ScreenPolicyRunner(
        child: IdleGate(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
