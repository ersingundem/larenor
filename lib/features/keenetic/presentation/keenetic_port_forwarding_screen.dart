import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/keenetic_providers.dart';
import 'keenetic_connect_screen.dart';

class KeeneticPortForwardingScreen extends ConsumerWidget {
  const KeeneticPortForwardingScreen({super.key});

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
        return const _RulesList();
      },
    );
  }
}

class _RulesList extends ConsumerWidget {
  const _RulesList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rulesAsync = ref.watch(keeneticPortForwardingProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Port Forwarding'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(keeneticPortForwardingProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: rulesAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('Failed to load: $error')),
          data: (rules) {
            if (rules.isEmpty) {
              return const Center(child: Text('No forwarding rules'));
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  footer: const Text(
                    'Read-only — manage rules in Keenetic Web.',
                  ),
                  children: [
                    for (final rule in rules)
                      CupertinoListTile(
                        leading: const Icon(
                          CupertinoIcons.arrow_right_arrow_left,
                        ),
                        title: Text(rule.label),
                        subtitle: rule.toAddress != null
                            ? Text('→ ${rule.toAddress}')
                            : null,
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
