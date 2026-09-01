import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/keenetic_access_point.dart';
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
          CupertinoPageScaffold(child: Center(child: Text(error.toString()))),
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
        middle: Text(AppLocalizations.of(context).keeneticWifi),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => ref.invalidate(keeneticAccessPointsProvider),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: apsAsync.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(
            child: Text(
              AppLocalizations.of(context).adminLoadError(error.toString()),
            ),
          ),
          data: (aps) {
            if (aps.isEmpty) {
              return Center(
                child: Text(
                  AppLocalizations.of(context).keeneticNoAccessPoints,
                ),
              );
            }
            return ListView(
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  children: [
                    for (final ap in aps)
                      CupertinoListTile(
                        title: Text(ap.name),
                        subtitle: Text(_interfaceLabel(context, ap.id)),
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

  String _interfaceLabel(BuildContext context, String id) {
    final parsed = parseKeeneticWifiInterfaceId(id);
    if (parsed == null) return id;
    return AppLocalizations.of(context)
        .keeneticWifiRadioLabel(parsed.$1, parsed.$2);
  }
}
