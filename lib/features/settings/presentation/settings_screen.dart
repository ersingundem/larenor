import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../auth/providers/auth_providers.dart';
import '../providers/settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(connectionConfigProvider).value;
    final keepScreenOn = ref.watch(keepScreenOnProvider);

    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Settings')),
      child: SafeArea(
        child: ListView(
          children: [
            const SizedBox(height: 16),
            CupertinoListSection.insetGrouped(
              header: const Text('CONNECTION'),
              children: [
                CupertinoListTile(
                  leading: const Icon(CupertinoIcons.house),
                  title: const Text('Home Assistant server'),
                  additionalInfo: Text(config?.baseUrl ?? 'Not connected'),
                ),
              ],
            ),
            CupertinoListSection.insetGrouped(
              header: const Text('DISPLAY'),
              children: [
                CupertinoListTile(
                  leading: const Icon(CupertinoIcons.brightness),
                  title: const Text('Keep screen on'),
                  subtitle: const Text('Recommended for wall-mounted tablets'),
                  trailing: CupertinoSwitch(
                    value: keepScreenOn.value ?? false,
                    onChanged: (value) =>
                        ref.read(keepScreenOnProvider.notifier).set(value),
                  ),
                ),
              ],
            ),
            CupertinoListSection.insetGrouped(
              children: [
                CupertinoListTile(
                  title: Center(
                    child: Text(
                      'Sign out',
                      style: TextStyle(
                        color: CupertinoColors.systemRed.resolveFrom(context),
                      ),
                    ),
                  ),
                  onTap: () async {
                    await ref.read(connectionConfigProvider.notifier).signOut();
                    if (context.mounted) context.go('/');
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
