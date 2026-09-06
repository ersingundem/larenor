import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/direct_home_access.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/settings_section.dart';
import '../providers/keenetic_providers.dart';
import 'keenetic_session_guard.dart';

class KeeneticPortForwardingScreen extends ConsumerWidget {
  const KeeneticPortForwardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    if (!ref.watch(directHomeAccessProvider).isCurrent) {
      return CupertinoPageScaffold(
        child: Center(child: Text(l10n.commonNotConnected)),
      );
    }
    final connectionAsync = ref.watch(keeneticConnectionProvider);

    return connectionAsync.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      skipError: false,
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) => CupertinoPageScaffold(
        child: Center(child: Text(l10n.healthReadError)),
      ),
      data: (config) {
        if (config == null) {
          return CupertinoPageScaffold(
            child: Center(child: Text(l10n.commonNotConnected)),
          );
        }
        return const _RulesList();
      },
    );
  }
}

class _RulesList extends ConsumerStatefulWidget {
  const _RulesList();
  @override
  ConsumerState<_RulesList> createState() => _RulesListState();
}

class _RulesListState extends KeeneticSessionState<_RulesList> {
  @override
  Widget build(BuildContext context) {
    watchKeeneticSession();
    final generation = sessionGeneration;
    if (!keeneticAvailable) {
      return CupertinoPageScaffold(
        child: Center(
          child: Text(AppLocalizations.of(context).commonNotConnected),
        ),
      );
    }
    final rulesAsync = ref.watch(keeneticPortForwardingProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(AppLocalizations.of(context).keeneticPortForwarding),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () {
            if (!keeneticCurrent(generation)) return;
            if (ref.read(keeneticClientProvider).hasError) {
              ref.invalidate(keeneticClientProvider);
            }
            ref.invalidate(keeneticPortForwardingProvider);
          },
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: rulesAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) =>
              Center(child: Text(AppLocalizations.of(context).healthReadError)),
          data: (rules) {
            if (rules.isEmpty) {
              return Center(
                child: Text(
                  AppLocalizations.of(context).keeneticNoForwardingRules,
                ),
              );
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
                SettingsSection(
                  footer: Text(
                    AppLocalizations.of(context).keeneticReadOnlyHint,
                  ),
                  children: [
                    for (final rule in rules)
                      CupertinoListTile(
                        leading: const Icon(
                          CupertinoIcons.arrow_right_arrow_left,
                        ),
                        title: Text(rule.label),
                        subtitle: rule.destination != null
                            ? Text(
                                '${rule.protocol.toUpperCase()}${rule.portRange == null ? '' : ' ${rule.portRange}'} → ${rule.destination}',
                              )
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
