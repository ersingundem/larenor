import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/power_budget_controller.dart';
import '../domain/power_budget_models.dart';

class PowerBudgetScreen extends StatefulWidget {
  const PowerBudgetScreen({super.key, required this.controller});
  final PowerBudgetController controller;
  @override
  State<PowerBudgetScreen> createState() => _PowerBudgetScreenState();
}

class _PowerBudgetScreenState extends State<PowerBudgetScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller.snapshot == null) {
        widget.controller.load();
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.setInteractive(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    return ServiceRootScaffold(
      title: l10n.powerBudgetTitle,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(l10n.powerBudgetStatus),
            footer: Text(l10n.powerBudgetManualBoundary),
            children: [
              _Status(controller: controller),
              SettingsActionTile(
                buttonKey: const ValueKey('power-budget-refresh'),
                leading: const Icon(CupertinoIcons.refresh),
                title: Text(l10n.powerBudgetRefresh),
                onTap: controller.state == PowerBudgetViewState.loading
                    ? null
                    : controller.load,
              ),
            ],
          ),
        ),
        if (snapshot != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Summary(snapshot: snapshot),
                  const SizedBox(height: 16),
                  if (snapshot.actions.isEmpty)
                    Semantics(
                      liveRegion: true,
                      child: Text(l10n.powerBudgetNoDeferral),
                    )
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final columns = constraints.maxWidth >= 900 ? 2 : 1;
                        final width =
                            (constraints.maxWidth - 16 * (columns - 1)) /
                            columns;
                        return Wrap(
                          spacing: 16,
                          runSpacing: 16,
                          children: [
                            for (final action in snapshot.actions)
                              SizedBox(
                                width: width,
                                child: _ActionCard(action: action),
                              ),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.controller});
  final PowerBudgetController controller;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = switch (controller.state) {
      PowerBudgetViewState.idle ||
      PowerBudgetViewState.loading => l10n.powerBudgetLoading,
      PowerBudgetViewState.ready => l10n.powerBudgetVerified,
      PowerBudgetViewState.failed => l10n.powerBudgetFailed,
      PowerBudgetViewState.stale => l10n.powerBudgetStale,
    };
    return Semantics(
      liveRegion: true,
      label: text,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              if (controller.state == PowerBudgetViewState.loading) ...[
                const CupertinoActivityIndicator(),
                const SizedBox(width: 12),
              ],
              Expanded(child: Text(text)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.snapshot});
  final PowerBudgetSnapshot snapshot;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _Card(
      label: l10n.powerBudgetSummary,
      children: [
        Text(
          l10n.powerBudgetSummary,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(l10n.powerBudgetImport(snapshot.gridImportW)),
        Text(l10n.powerBudgetLimit(snapshot.gridLimitW)),
        Text(l10n.powerBudgetReduction(snapshot.requiredReductionW)),
        const SizedBox(height: 8),
        Text(
          l10n.powerBudgetManualOnly,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.action});
  final PowerBudgetAction action;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _Card(
      label: action.label,
      children: [
        Text(
          action.label,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(l10n.powerBudgetDefer(action.reductionW)),
        Text(l10n.powerBudgetTarget(action.targetW)),
        Text(l10n.powerBudgetPriority(action.priority)),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.label, required this.children});
  final String label;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: label,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    ),
  );
}
