import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/settings_section.dart';
import '../../../shared/widgets/app_page_scaffold.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../providers/admin_providers.dart';
import 'add_integration_screen.dart';

/// Resumes server-created discovery and reauthentication flows. Reauth must
/// resume HA's existing flow; POSTing a new user flow is not reauthentication.
class PendingFlowsScreen extends ConsumerStatefulWidget {
  const PendingFlowsScreen({super.key});
  @override
  ConsumerState<PendingFlowsScreen> createState() => _PendingFlowsScreenState();
}

class _PendingFlowsScreenState extends ConsumerState<PendingFlowsScreen> {
  late Future<List<Map<String, dynamic>>> _flows;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _flows =
        ref.read(haAdminClientProvider)?.getPendingFlows() ?? Future.value([]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.adminPendingFlows),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => setState(_load),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: FutureBuilder(
          future: _flows,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text(l10n.adminLoadError(snapshot.error.toString())),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CupertinoActivityIndicator());
            }
            if (snapshot.data!.isEmpty) {
              return Center(child: Text(l10n.commonNoData));
            }
            return ListView(
              children: [
                SettingsSection(
                  children: [
                    for (final flow in snapshot.data!)
                      CupertinoListTile(
                        title: Text('${flow['handler'] ?? ''}'),
                        subtitle: Text(
                          '${(flow['context'] as Map?)?['source'] ?? flow['step_id'] ?? ''}',
                        ),
                        trailing: const CupertinoListTileChevron(),
                        onTap: flow['flow_id'] is! String
                            ? null
                            : () async {
                                await Navigator.of(context).push(
                                  CupertinoPageRoute<void>(
                                    builder: (_) => AddIntegrationScreen(
                                      flowId: flow['flow_id'] as String,
                                    ),
                                  ),
                                );
                                if (mounted) setState(_load);
                              },
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
