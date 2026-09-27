import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../home_resources/data/home_resources_providers.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../data/home_workflow_controller.dart';
import '../domain/home_workflow_models.dart';

final class HomeWorkflowStrings {
  const HomeWorkflowStrings({
    required this.title,
    required this.subtitle,
    required this.create,
    required this.name,
    required this.namePlaceholder,
    required this.resource,
    required this.selectResource,
    required this.noWritableResources,
    required this.deadlineMinutes,
    required this.turnOn,
    required this.turnOff,
    required this.loading,
    required this.empty,
    required this.offline,
    required this.error,
    required this.uncertain,
    required this.refresh,
    required this.checkResult,
    required this.loadMore,
    required this.approve,
    required this.cancel,
    required this.resume,
    required this.effectApplied,
    required this.effectNotApplied,
    required this.attempt,
    required this.deadline,
    required this.state,
    required this.reconciliation,
    required this.waitingDecision,
    required this.running,
    required this.reconciliationRequired,
    required this.completed,
    required this.failed,
    required this.cancelled,
    required this.timedOut,
    required this.resultNone,
    required this.resultApplied,
    required this.resultNotApplied,
  });

  factory HomeWorkflowStrings.fromLocalizations(AppLocalizations value) =>
      HomeWorkflowStrings(
        title: value.homeWorkflowsTitle,
        subtitle: value.homeWorkflowsSubtitle,
        create: value.homeWorkflowsCreate,
        name: value.homeWorkflowsName,
        namePlaceholder: value.homeWorkflowsNamePlaceholder,
        resource: value.homeWorkflowsResource,
        selectResource: value.homeWorkflowsSelectResource,
        noWritableResources: value.homeWorkflowsNoWritableResources,
        deadlineMinutes: value.homeWorkflowsDeadlineMinutes,
        turnOn: value.homeWorkflowsTurnOn,
        turnOff: value.homeWorkflowsTurnOff,
        loading: value.homeWorkflowsLoading,
        empty: value.homeWorkflowsEmpty,
        offline: value.homeWorkflowsOffline,
        error: value.homeWorkflowsError,
        uncertain: value.homeWorkflowsUncertain,
        refresh: value.homeWorkflowsRefresh,
        checkResult: value.homeWorkflowsCheckResult,
        loadMore: value.homeWorkflowsLoadMore,
        approve: value.homeWorkflowsApprove,
        cancel: value.commonCancel,
        resume: value.homeWorkflowsResume,
        effectApplied: value.homeWorkflowsEffectApplied,
        effectNotApplied: value.homeWorkflowsEffectNotApplied,
        attempt: value.homeWorkflowsAttempt,
        deadline: value.homeWorkflowsDeadline,
        state: value.homeWorkflowsState,
        reconciliation: value.homeWorkflowsReconciliation,
        waitingDecision: value.homeWorkflowsStateWaitingDecision,
        running: value.homeWorkflowsStateRunning,
        reconciliationRequired: value.homeWorkflowsStateReconciliationRequired,
        completed: value.homeWorkflowsStateCompleted,
        failed: value.homeWorkflowsStateFailed,
        cancelled: value.homeWorkflowsStateCancelled,
        timedOut: value.homeWorkflowsStateTimedOut,
        resultNone: value.homeWorkflowsResultNone,
        resultApplied: value.homeWorkflowsResultApplied,
        resultNotApplied: value.homeWorkflowsResultNotApplied,
      );

  final String title,
      subtitle,
      create,
      name,
      namePlaceholder,
      resource,
      selectResource,
      noWritableResources,
      deadlineMinutes,
      turnOn,
      turnOff,
      loading,
      empty,
      offline,
      error,
      uncertain,
      refresh,
      checkResult,
      loadMore,
      approve,
      cancel,
      resume,
      effectApplied,
      effectNotApplied,
      attempt,
      deadline,
      state,
      reconciliation,
      waitingDecision,
      running,
      reconciliationRequired,
      completed,
      failed,
      cancelled,
      timedOut,
      resultNone,
      resultApplied,
      resultNotApplied;
}

final class HomeWorkflowScreen extends ConsumerStatefulWidget {
  const HomeWorkflowScreen({
    super.key,
    required this.controller,
    required this.strings,
  });

  final HomeWorkflowController controller;
  final HomeWorkflowStrings strings;

  @override
  ConsumerState<HomeWorkflowScreen> createState() => _HomeWorkflowScreenState();
}

final class _HomeWorkflowScreenState extends ConsumerState<HomeWorkflowScreen> {
  late HomeWorkflowLease _lease;
  final _name = TextEditingController();
  final _deadline = TextEditingController(text: '5');
  String? _resourceId;
  HomeWorkflowAction _action = HomeWorkflowAction.turnOn;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _lease = widget.controller.bind();
    widget.controller.addListener(_changed);
    widget.controller.load(_lease);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant HomeWorkflowScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      oldWidget.controller.detach(_lease);
      _attach();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.detach(_lease);
    _name.dispose();
    _deadline.dispose();
    super.dispose();
  }

  bool get _actionsEnabled =>
      widget.controller.state == HomeWorkflowViewState.ready ||
      widget.controller.state == HomeWorkflowViewState.empty;

  List<HomeResourceRecord> _writableResources() {
    final catalog = ref.watch(sharedHomeResourcesProvider);
    if (catalog == null || !catalog.fresh || catalog.stale) return const [];
    return <HomeResourceRecord>[
      for (final entry in catalog.entries)
        if (entry.kind == HomeResourceKind.resource && entry.canWrite) entry,
    ]..sort((a, b) {
      final order = a.order.compareTo(b.order);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
  }

  HomeResourceRecord? _selected(List<HomeResourceRecord> resources) {
    for (final resource in resources) {
      if (resource.id == _resourceId) return resource;
    }
    return null;
  }

  Future<void> _chooseResource(List<HomeResourceRecord> resources) async {
    if (!_actionsEnabled || resources.isEmpty) return;
    final selected = await showCupertinoModalPopup<HomeResourceRecord>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(widget.strings.selectResource),
        actions: [
          for (final resource in resources)
            CupertinoActionSheetAction(
              key: ValueKey('home-workflow-resource-${resource.id}'),
              onPressed: () => Navigator.pop(context, resource),
              child: Text(resource.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.strings.cancel),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => _resourceId = selected.id);
    }
  }

  void _create(HomeResourceRecord target) {
    final minutes = int.tryParse(_deadline.text);
    if (!_actionsEnabled ||
        _name.text.trim().isEmpty ||
        minutes == null ||
        minutes < 1 ||
        minutes > 1440) {
      return;
    }
    widget.controller.create(
      _lease,
      title: _name.text,
      deadlineSeconds: minutes * 60,
      target: target,
      action: _action,
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final resources = _writableResources();
    final selected = _selected(resources);
    if (_resourceId != null && selected == null) _resourceId = null;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(strings.title)),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = constraints.maxWidth >= 900 ? 32.0 : 16.0;
            final cardWidth = constraints.maxWidth >= 900
                ? (constraints.maxWidth - horizontal * 2 - 16) / 2
                : constraints.maxWidth - horizontal * 2;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(horizontal, 24, horizontal, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(strings.subtitle),
                  const SizedBox(height: 16),
                  _createCard(strings, resources, selected),
                  const SizedBox(height: 20),
                  ..._status(strings),
                  if (widget.controller.workflows.isNotEmpty) ...[
                    Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        for (final workflow in widget.controller.workflows)
                          SizedBox(
                            width: cardWidth,
                            child: _workflowCard(strings, workflow, resources),
                          ),
                      ],
                    ),
                    if (widget.controller.canLoadMore) ...[
                      const SizedBox(height: 20),
                      _ActionButton(
                        key: const ValueKey('home-workflow-load-more'),
                        label: strings.loadMore,
                        semanticLabel: strings.loadMore,
                        onPressed: () =>
                            widget.controller.load(_lease, more: true),
                      ),
                    ],
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _createCard(
    HomeWorkflowStrings strings,
    List<HomeResourceRecord> resources,
    HomeResourceRecord? selected,
  ) {
    final enabled = _actionsEnabled;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              strings.create,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Semantics(
              textField: true,
              label: strings.name,
              child: CupertinoTextField(
                key: const ValueKey('home-workflow-name'),
                controller: _name,
                enabled: enabled,
                placeholder: strings.namePlaceholder,
                minLines: 1,
                maxLines: 2,
                inputFormatters: [LengthLimitingTextInputFormatter(80)],
                padding: const EdgeInsets.all(14),
              ),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              key: const ValueKey('home-workflow-select-resource'),
              label: selected?.label ?? strings.selectResource,
              semanticLabel:
                  '${strings.resource}: ${selected?.label ?? strings.selectResource}',
              onPressed: enabled && resources.isNotEmpty
                  ? () => _chooseResource(resources)
                  : null,
            ),
            if (resources.isEmpty) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(strings.noWritableResources),
              ),
            ],
            const SizedBox(height: 12),
            Semantics(
              textField: true,
              label: strings.deadlineMinutes,
              child: CupertinoTextField(
                key: const ValueKey('home-workflow-deadline'),
                controller: _deadline,
                enabled: enabled,
                keyboardType: TextInputType.number,
                placeholder: strings.deadlineMinutes,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                padding: const EdgeInsets.all(14),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: IgnorePointer(
                ignoring: !enabled,
                child: Opacity(
                  opacity: enabled ? 1 : 0.5,
                  child: CupertinoSlidingSegmentedControl<HomeWorkflowAction>(
                    groupValue: _action,
                    children: {
                      HomeWorkflowAction.turnOn: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(strings.turnOn),
                      ),
                      HomeWorkflowAction.turnOff: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(strings.turnOff),
                      ),
                    },
                    onValueChanged: (value) {
                      if (enabled && value != null) {
                        setState(() => _action = value);
                      }
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _ActionButton(
              key: const ValueKey('home-workflow-create'),
              label: strings.create,
              semanticLabel: strings.create,
              filled: true,
              onPressed: enabled && selected != null
                  ? () => _create(selected)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _status(HomeWorkflowStrings strings) {
    final state = widget.controller.state;
    return switch (state) {
      HomeWorkflowViewState.detached ||
      HomeWorkflowViewState.idle ||
      HomeWorkflowViewState.loading => [
        _Status(strings.loading, const CupertinoActivityIndicator()),
        const SizedBox(height: 20),
      ],
      HomeWorkflowViewState.empty => [
        _Status(strings.empty, const Icon(CupertinoIcons.tray)),
        const SizedBox(height: 20),
      ],
      HomeWorkflowViewState.offline => [
        _Status(strings.offline, const Icon(CupertinoIcons.wifi_slash)),
        const SizedBox(height: 12),
        _ActionButton(
          key: const ValueKey('home-workflow-refresh'),
          label: strings.refresh,
          semanticLabel: strings.refresh,
          onPressed: () => widget.controller.load(_lease),
        ),
        const SizedBox(height: 20),
      ],
      HomeWorkflowViewState.error => [
        _Status(
          strings.error,
          const Icon(CupertinoIcons.exclamationmark_triangle),
        ),
        const SizedBox(height: 12),
        _ActionButton(
          key: const ValueKey('home-workflow-refresh'),
          label: strings.refresh,
          semanticLabel: strings.refresh,
          onPressed: () => widget.controller.load(_lease),
        ),
        const SizedBox(height: 20),
      ],
      HomeWorkflowViewState.uncertain => [
        _Status(strings.uncertain, const Icon(CupertinoIcons.clock)),
        const SizedBox(height: 12),
        _ActionButton(
          key: const ValueKey('home-workflow-check-result'),
          label: strings.checkResult,
          semanticLabel: strings.checkResult,
          onPressed: () => widget.controller.reconcile(_lease),
        ),
        const SizedBox(height: 20),
      ],
      HomeWorkflowViewState.ready || HomeWorkflowViewState.busy => const [],
    };
  }

  Widget _workflowCard(
    HomeWorkflowStrings strings,
    HomeWorkflow workflow,
    List<HomeResourceRecord> resources,
  ) {
    final enabled =
        _actionsEnabled &&
        resources.any(
          (resource) =>
              resource.id == workflow.target.resourceId && resource.canWrite,
        );
    final stateLabel = switch (workflow.state) {
      HomeWorkflowState.waitingDecision => strings.waitingDecision,
      HomeWorkflowState.running => strings.running,
      HomeWorkflowState.reconciliationRequired =>
        strings.reconciliationRequired,
      HomeWorkflowState.completed => strings.completed,
      HomeWorkflowState.failed => strings.failed,
      HomeWorkflowState.cancelled => strings.cancelled,
      HomeWorkflowState.timedOut => strings.timedOut,
    };
    final reconciliation = switch (workflow.reconciliationResult) {
      HomeWorkflowReconciliationResult.none => strings.resultNone,
      HomeWorkflowReconciliationResult.effectApplied => strings.resultApplied,
      HomeWorkflowReconciliationResult.effectNotApplied =>
        strings.resultNotApplied,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              workflow.title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text('${strings.state}: $stateLabel'),
            Text('${strings.attempt}: ${workflow.attempt}'),
            Text(
              '${strings.deadline}: ${workflow.deadlineAt.toLocal().toIso8601String().substring(0, 16)}',
            ),
            Text('${strings.reconciliation}: $reconciliation'),
            if (!workflow.terminal) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: _workflowActions(strings, workflow, enabled: enabled),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _workflowActions(
    HomeWorkflowStrings strings,
    HomeWorkflow workflow, {
    required bool enabled,
  }) {
    if (workflow.state == HomeWorkflowState.waitingDecision) {
      return [
        _ActionButton(
          key: ValueKey('home-workflow-approve-${workflow.id}'),
          label: strings.approve,
          semanticLabel: '${strings.approve} ${workflow.title}',
          filled: true,
          onPressed: enabled
              ? () => widget.controller.approve(_lease, workflow)
              : null,
        ),
        _ActionButton(
          key: ValueKey('home-workflow-cancel-${workflow.id}'),
          label: strings.cancel,
          semanticLabel: '${strings.cancel} ${workflow.title}',
          onPressed: enabled
              ? () => widget.controller.cancel(_lease, workflow)
              : null,
        ),
      ];
    }
    if (workflow.state == HomeWorkflowState.reconciliationRequired) {
      return [
        _ActionButton(
          key: ValueKey('home-workflow-resume-${workflow.id}'),
          label: strings.resume,
          semanticLabel: '${strings.resume} ${workflow.title}',
          onPressed: enabled
              ? () => widget.controller.resume(_lease, workflow)
              : null,
        ),
        _ActionButton(
          key: ValueKey('home-workflow-applied-${workflow.id}'),
          label: strings.effectApplied,
          semanticLabel: '${strings.effectApplied} ${workflow.title}',
          filled: true,
          onPressed: enabled
              ? () => widget.controller.effectApplied(_lease, workflow)
              : null,
        ),
        _ActionButton(
          key: ValueKey('home-workflow-not-applied-${workflow.id}'),
          label: strings.effectNotApplied,
          semanticLabel: '${strings.effectNotApplied} ${workflow.title}',
          onPressed: enabled
              ? () => widget.controller.effectNotApplied(_lease, workflow)
              : null,
        ),
      ];
    }
    return const [];
  }
}

final class _Status extends StatelessWidget {
  const _Status(this.label, this.icon);
  final String label;
  final Widget icon;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          const SizedBox(width: 12),
          Flexible(child: Text(label)),
        ],
      ),
    ),
  );
}

final class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
    this.filled = false,
  });

  final String label, semanticLabel;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semanticLabel,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      child: filled
          ? CupertinoButton.filled(onPressed: onPressed, child: Text(label))
          : CupertinoButton(onPressed: onPressed, child: Text(label)),
    ),
  );
}
