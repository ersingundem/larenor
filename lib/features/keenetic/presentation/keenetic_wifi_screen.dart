import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/keenetic_providers.dart';
import 'keenetic_connect_screen.dart';

class KeeneticWifiScreen extends ConsumerWidget {
  const KeeneticWifiScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionAsync = ref.watch(keeneticConnectionProvider);

    return connectionAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text('$error'))),
      data: (config) {
        if (config == null) return const KeeneticConnectScreen();
        return const _AccessPointsList();
      },
    );
  }
}

class _AccessPointsList extends ConsumerWidget {
  const _AccessPointsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apsAsync = ref.watch(keeneticAccessPointsProvider);
    final clientAsync = ref.watch(keeneticClientProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Wi-Fi'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(keeneticAccessPointsProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: apsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (aps) {
            if (aps.isEmpty) {
              return const Center(child: Text('No access points found'));
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final ap in aps)
                      CupertinoListTile(
                        title: Text(ap.name),
                        subtitle: Text(ap.id),
                        trailing: CupertinoSwitch(
                          value: ap.up,
                          onChanged: clientAsync.value == null
                              ? null
                              : (value) async {
                                  await clientAsync.value!.setInterfaceUp(
                                    ap.id,
                                    value,
                                  );
                                  ref.invalidate(keeneticAccessPointsProvider);
                                },
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
