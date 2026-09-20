import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import 'add_integration_screen.dart';
import 'admin_session_state.dart';

/// Resumes server-created discovery and reauthentication flows. Reauth must
/// resume HA's existing flow; POSTing a new user flow is not reauthentication.
class PendingFlowsScreen extends ConsumerStatefulWidget {
  const PendingFlowsScreen({super.key});

  @override
  ConsumerState<PendingFlowsScreen> createState() => _PendingFlowsScreenState();
}

class _PendingFlowsScreenState extends AdminSessionState<PendingFlowsScreen> {
  List<Map<String, dynamic>>? _flows;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && adminAuthorityCurrent) {
        _load(adminActionGeneration);
      }
    });
  }

  Future<void> _load(int generation) async {
    final client = adminClient;
    if (client == null || !adminActionCurrent(generation)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final flows = await client.getPendingFlows();
      if (!mounted || !adminActionCurrent(generation)) return;
      setState(() {
        _flows = flows;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || !adminActionCurrent(generation)) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _open(String flowId, int generation) async {
    if (!adminActionCurrent(generation)) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => AddIntegrationScreen(flowId: flowId),
      ),
    );
    if (!mounted || !adminAuthorityCurrent) return;
    setState(() {});
    await _load(adminActionGeneration);
  }

  @override
  Widget build(BuildContext context) {
    watchAdminSession();
    final l10n = AppLocalizations.of(context);
    final generation = adminActionGeneration;
    return ServiceRootScaffold(
      title: l10n.adminPendingFlows,
      trailing: Semantics(
        key: const ValueKey('pending-flows-refresh-action'),
        button: true,
        enabled: !_loading && adminActionCurrent(generation),
        label: l10n.commonRefresh,
        child: CupertinoButton(
          minimumSize: const Size(48, 48),
          padding: EdgeInsets.zero,
          onPressed: _loading || !adminActionCurrent(generation)
              ? null
              : () => _load(generation),
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      slivers: [
        if (!adminAuthorityCurrent)
          SliverFilledMessage(
            child: Semantics(
              liveRegion: true,
              child: Text(l10n.adminEditorSessionChanged),
            ),
          )
        else if (_loading)
          SliverFilledMessage(
            child: Semantics(
              liveRegion: true,
              label: l10n.commonLoading,
              child: const CupertinoActivityIndicator(),
            ),
          )
        else if (_error != null)
          SliverFillRemaining(
            child: Center(
              child: SettingsSection(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(l10n.adminLoadError(_error!)),
                    ),
                  ),
                  SettingsActionTile(
                    buttonKey: const ValueKey('pending-flows-retry-action'),
                    leading: const Icon(CupertinoIcons.refresh),
                    title: Text(l10n.commonRetry),
                    onTap: () => _load(generation),
                  ),
                ],
              ),
            ),
          )
        else if (_flows?.isEmpty != false)
          SliverFilledMessage(child: Text(l10n.commonNoData))
        else
          SliverSafeArea(
            top: false,
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 16),
                SettingsSection(
                  header: Semantics(
                    key: const ValueKey('pending-flows-heading'),
                    header: true,
                    child: Text(l10n.adminPendingFlows),
                  ),
                  children: [
                    for (final flow in _flows!)
                      SettingsActionTile(
                        buttonKey: ValueKey(
                          'pending-flow-${flow['flow_id'] ?? 'invalid'}',
                        ),
                        title: Text('${flow['handler'] ?? ''}'),
                        additionalInfo: Text(
                          '${(flow['context'] as Map?)?['source'] ?? flow['step_id'] ?? ''}',
                        ),
                        onTap: flow['flow_id'] is! String
                            ? null
                            : () =>
                                  _open(flow['flow_id'] as String, generation),
                      ),
                  ],
                ),
              ]),
            ),
          ),
      ],
    );
  }
}
