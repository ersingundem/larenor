import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/keenetic_api_exception.dart';
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

class _AccessPointsList extends ConsumerStatefulWidget {
  const _AccessPointsList();

  @override
  ConsumerState<_AccessPointsList> createState() => _AccessPointsListState();
}

class _AccessPointsListState extends ConsumerState<_AccessPointsList> {
  final Set<String> _pending = {};

  Future<void> _setUp(KeeneticAccessPoint ap, bool value) async {
    if (_pending.contains(ap.id)) return;
    final l10n = AppLocalizations.of(context);
    if (!value) {
      final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(l10n.keeneticDisableWifiTitle),
          content: Text(l10n.keeneticDisableWifiMessage(ap.ssid ?? ap.name)),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.commonCancel),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.keeneticTurnOff),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _pending.add(ap.id));
    try {
      final client = await ref.read(keeneticClientProvider.future);
      if (client == null) throw KeeneticApiException(l10n.commonNotConnected);
      await client.setInterfaceUp(ap.id, value);
      if (!mounted) return;
      ref.invalidate(keeneticAccessPointsProvider);
    } catch (error) {
      if (!mounted) return;
      setState(() => _pending.remove(ap.id));
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(l10n.commonError),
          content: Text(
            error is KeeneticApiException
                ? error.message
                : l10n.keeneticErrorUnreachable,
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.commonOk),
            ),
          ],
        ),
      );
    } finally {
      if (mounted && _pending.contains(ap.id)) {
        setState(() => _pending.remove(ap.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final apsAsync = ref.watch(keeneticAccessPointsProvider);
    final clientAsync = ref.watch(keeneticClientProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(AppLocalizations.of(context).keeneticWifi),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () {
            if (ref.read(keeneticClientProvider).hasError) {
              ref.invalidate(keeneticClientProvider);
            }
            ref.invalidate(keeneticAccessPointsProvider);
          },
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
                  footer: Text(
                    AppLocalizations.of(context).keeneticWifiChangesSaved,
                  ),
                  children: [
                    for (final ap in aps)
                      CupertinoListTile(
                        title: Text(ap.name),
                        leading: Icon(
                          ap.up
                              ? CupertinoIcons.wifi
                              : CupertinoIcons.wifi_slash,
                          color: ap.up
                              ? CupertinoColors.systemBlue
                              : CupertinoColors.systemGrey,
                        ),
                        subtitle: Text(
                          [
                            if (ap.ssid != null && ap.ssid != ap.name) ap.ssid!,
                            _interfaceLabel(context, ap.id),
                          ].join(' · '),
                        ),
                        trailing: _pending.contains(ap.id)
                            ? const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 14),
                                child: CupertinoActivityIndicator(),
                              )
                            : CupertinoSwitch(
                                value: ap.up,
                                onChanged:
                                    clientAsync.value == null ||
                                        parseKeeneticWifiInterfaceId(ap.id) ==
                                            null
                                    ? null
                                    : (value) => _setUp(ap, value),
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
