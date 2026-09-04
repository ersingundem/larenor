import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/flow_schema_field.dart';
import '../data/models/flow_step.dart';
import '../providers/admin_providers.dart';
import 'widgets/dynamic_form_field.dart';
import '../../../shared/theme/typography.dart';

class AddIntegrationScreen extends ConsumerStatefulWidget {
  const AddIntegrationScreen({super.key});

  @override
  ConsumerState<AddIntegrationScreen> createState() =>
      _AddIntegrationScreenState();
}

class _AddIntegrationScreenState extends ConsumerState<AddIntegrationScreen> {
  List<String>? _handlers;
  String _query = '';
  String? _handlersError;

  FlowStep? _step;
  final _formValues = <String, dynamic>{};
  bool _submitting = false;
  String? _stepError;

  @override
  void initState() {
    super.initState();
    _loadHandlers();
  }

  Future<void> _loadHandlers() async {
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;
    try {
      final handlers = await client.listFlowHandlers();
      if (mounted) setState(() => _handlers = handlers);
    } catch (e) {
      if (mounted) setState(() => _handlersError = e.toString());
    }
  }

  Future<void> _startFlow(String handler) async {
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;
    setState(() => _submitting = true);
    try {
      final step = await client.startFlow(handler);
      setState(() {
        _step = step;
        _formValues.clear();
        _stepError = null;
      });
    } catch (e) {
      setState(() => _stepError = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitStep(Map<String, dynamic> data) async {
    final client = ref.read(haAdminClientProvider);
    final flowId = _step?.flowId;
    if (client == null || flowId == null) return;

    setState(() => _submitting = true);
    try {
      final next = await client.submitFlowStep(flowId, data);
      setState(() {
        _step = next;
        _formValues.clear();
        _stepError = null;
      });
      if (next.type == 'create_entry') {
        await ref.read(configEntriesProvider.notifier).refresh();
      }
    } catch (e) {
      setState(() => _stepError = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(AppLocalizations.of(context).addIntegrationTitle),
      ),
      child: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final step = _step;
    if (step == null) return _buildHandlerPicker(context);

    switch (step.type) {
      case 'create_entry':
        return _buildResult(
          icon: CupertinoIcons.check_mark_circled,
          message: l10n.addIntegrationSuccess,
        );
      case 'abort':
        return _buildResult(
          icon: CupertinoIcons.exclamationmark_circle,
          message: step.reason ?? l10n.addIntegrationAborted,
        );
      case 'menu':
        return _buildMenu(step);
      default:
        return _buildForm(step);
    }
  }

  Widget _buildHandlerPicker(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_handlersError != null) {
      return Center(child: Text(l10n.adminLoadError(_handlersError!)));
    }
    if (_handlers == null) {
      return const Center(child: CupertinoActivityIndicator());
    }

    final filtered = _query.isEmpty
        ? _handlers!
        : _handlers!.where((h) => h.contains(_query.toLowerCase())).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: CupertinoSearchTextField(
            placeholder: l10n.addIntegrationSearchPlaceholder,
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            l10n.addIntegrationHint,
            style: TextStyle(
              fontSize: AppText.hint.fontSize,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final handler = filtered[index];
              return CupertinoListTile(
                title: Text(handler),
                onTap: _submitting ? null : () => _startFlow(handler),
              );
            },
          ),
        ),
        if (_submitting)
          const Padding(
            padding: EdgeInsets.all(12),
            child: CupertinoActivityIndicator(),
          ),
      ],
    );
  }

  Widget _buildMenu(FlowStep step) {
    final options = step.menuOptions ?? const [];
    return ListView(
      children: [
        const SizedBox(height: 16),
        CupertinoListSection.insetGrouped(
          header: step.title != null ? Text(step.title!) : null,
          children: [
            for (final option in options)
              CupertinoListTile(
                title: Text(option),
                trailing: const CupertinoListTileChevron(),
                onTap: _submitting
                    ? null
                    : () => _submitStep({'next_step_id': option}),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildForm(FlowStep step) {
    return ListView(
      children: [
        const SizedBox(height: 16),
        if (_stepError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _stepError!,
              style: TextStyle(
                color: CupertinoColors.systemRed.resolveFrom(context),
              ),
            ),
          ),
        CupertinoListSection.insetGrouped(
          header: Text(
            step.stepId ?? AppLocalizations.of(context).addIntegrationSetup,
          ),
          children: [
            for (final field in step.dataSchema)
              DynamicFormField(
                key: ValueKey(field.name),
                field: field,
                value: _formValues[field.name],
                onChanged: (value) =>
                    setState(() => _formValues[field.name] = value),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: CupertinoButton.filled(
            onPressed: _submitting
                ? null
                : () => _submitStep(_valuesForSubmit(step.dataSchema)),
            child: _submitting
                ? const CupertinoActivityIndicator(color: CupertinoColors.white)
                : Text(AppLocalizations.of(context).commonNext),
          ),
        ),
      ],
    );
  }

  Map<String, dynamic> _valuesForSubmit(List<FlowSchemaField> fields) {
    final values = <String, dynamic>{};
    for (final field in fields) {
      final value = _formValues[field.name] ?? field.defaultValue;
      if (value != null) values[field.name] = value;
    }
    return values;
  }

  Widget _buildResult({required IconData icon, required String message}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 48,
              color: CupertinoTheme.of(context).primaryColor,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            CupertinoButton.filled(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(AppLocalizations.of(context).commonDone),
            ),
          ],
        ),
      ),
    );
  }
}
