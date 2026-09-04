import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/app_page_scaffold.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/flow_schema_field.dart';
import '../data/models/flow_step.dart';
import '../providers/admin_providers.dart';
import '../data/admin_client.dart';
import 'widgets/dynamic_form_field.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/settings_section.dart';

class AddIntegrationScreen extends ConsumerStatefulWidget {
  const AddIntegrationScreen({
    super.key,
    this.handler,
    this.entryId,
    this.flowId,
    this.options = false,
  });
  final String? handler;
  final String? entryId;
  final String? flowId;
  final bool options;

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
  int _formRevision = 0;
  bool _submitting = false;
  String? _stepError;
  Timer? _progressTimer;
  HaAdminClient? _client;
  bool _ownsFlow = false;

  @override
  void initState() {
    super.initState();
    _client = ref.read(haAdminClientProvider);
    if (widget.flowId != null) {
      _fetchFlow(widget.flowId!);
    } else if (widget.handler != null) {
      _startFlow(widget.handler!);
    } else {
      _loadHandlers();
    }
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
      final step = await client.startFlow(
        handler,
        entryId: widget.entryId,
        options: widget.options,
      );
      _ownsFlow = true;
      if (!mounted) {
        if (step.flowId != null) {
          await client.cancelFlow(step.flowId!, options: widget.options);
        }
        return;
      }
      _acceptStep(step);
    } catch (e) {
      if (mounted) setState(() => _stepError = e.toString());
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
      final next = await client.submitFlowStep(
        flowId,
        data,
        options: widget.options,
      );
      if (!mounted) return;
      _acceptStep(next);
    } catch (e) {
      if (mounted) setState(() => _stepError = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          widget.options
              ? AppLocalizations.of(context).adminOptions
              : widget.entryId != null
              ? AppLocalizations.of(context).adminReconfigure
              : AppLocalizations.of(context).addIntegrationTitle,
        ),
      ),
      child: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final step = _step;
    if (step == null) {
      if (widget.handler != null || widget.flowId != null) {
        return Center(
          child: _stepError == null
              ? const CupertinoActivityIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_stepError!),
                    CupertinoButton(
                      onPressed: () => widget.flowId != null
                          ? _fetchFlow(widget.flowId!)
                          : _startFlow(widget.handler!),
                      child: Text(l10n.commonRetry),
                    ),
                  ],
                ),
        );
      }
      return _buildHandlerPicker(context);
    }

    switch (step.type) {
      case 'create_entry':
        return _buildResult(
          icon: CupertinoIcons.check_mark_circled,
          message: widget.options || widget.entryId != null
              ? l10n.commonDone
              : l10n.addIntegrationSuccess,
        );
      case 'abort':
        return _buildResult(
          icon: CupertinoIcons.exclamationmark_circle,
          message: step.reason ?? l10n.addIntegrationAborted,
        );
      case 'menu':
        return _buildMenu(step);
      case 'progress':
      case 'progress_done':
      case 'external_done':
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CupertinoActivityIndicator(),
              const SizedBox(height: 16),
              Text(l10n.adminFlowWaiting),
              if (_stepError != null) Text(_stepError!),
              CupertinoButton(
                onPressed: _submitting ? null : () => _fetchFlow(step.flowId!),
                child: Text(l10n.commonRefresh),
              ),
            ],
          ),
        );
      case 'external':
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.adminFlowExternal, textAlign: TextAlign.center),
                if (step.url != null)
                  CupertinoButton.filled(
                    onPressed: () => _openExternal(step.url!),
                    child: Text(l10n.commonNext),
                  ),
                CupertinoButton(
                  onPressed: _submitting
                      ? null
                      : () => _fetchFlow(step.flowId!),
                  child: Text(l10n.commonRefresh),
                ),
                if (_stepError != null) Text(_stepError!),
              ],
            ),
          ),
        );
      default:
        return _buildForm(step);
    }
  }

  Widget _buildHandlerPicker(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_handlersError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.adminLoadError(_handlersError!)),
            CupertinoButton(
              onPressed: () {
                setState(() => _handlersError = null);
                _loadHandlers();
              },
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
      );
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
        if (_stepError != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _stepError!,
              style: const TextStyle(color: CupertinoColors.systemRed),
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
        SettingsSection(
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
        if (step.errors?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              step.errors!.entries
                  .map((entry) => '${entry.key}: ${entry.value}')
                  .join('\n'),
              style: const TextStyle(color: CupertinoColors.systemRed),
            ),
          ),
        if (step.descriptionPlaceholders?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(step.descriptionPlaceholders!.values.join('\n')),
          ),
        SettingsSection(
          header: Text(
            step.stepId ?? AppLocalizations.of(context).addIntegrationSetup,
          ),
          children: [
            for (final field in step.dataSchema)
              DynamicFormField(
                key: ValueKey(
                  '${step.flowId}:${step.stepId}:${field.name}:$_formRevision',
                ),
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
                : () {
                    try {
                      _submitStep(
                        normalizeFlowValues(step.dataSchema, _formValues),
                      );
                    } on FormatException catch (error) {
                      setState(
                        () => _stepError =
                            '${AppLocalizations.of(context).adminInvalidValue} ${error.message}',
                      );
                    }
                  },
            child: _submitting
                ? const CupertinoActivityIndicator(color: CupertinoColors.white)
                : Text(AppLocalizations.of(context).commonNext),
          ),
        ),
      ],
    );
  }

  void _acceptStep(FlowStep next) {
    final sameStep =
        _step?.stepId == next.stepId && _step?.flowId == next.flowId;
    setState(() {
      _step = next;
      if (!sameStep || next.errors?.isNotEmpty != true) {
        _formValues.clear();
        _formRevision++;
      }
      _stepError = null;
    });
    _progressTimer?.cancel();
    if (['progress', 'progress_done', 'external_done'].contains(next.type) &&
        next.flowId != null) {
      _progressTimer = Timer(
        const Duration(seconds: 2),
        () => _fetchFlow(next.flowId!),
      );
    }
    if (next.type == 'create_entry' || next.type == 'abort') {
      ref.invalidate(configEntriesProvider);
    }
  }

  Future<void> _fetchFlow(String flowId) async {
    final client = _client;
    if (client == null || _submitting) return;
    setState(() => _submitting = true);
    try {
      final next = await client.getFlow(flowId, options: widget.options);
      if (mounted) _acceptStep(next);
    } catch (error) {
      if (mounted) setState(() => _stepError = error.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !['https', 'http'].contains(uri.scheme)) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(builder: (_) => _ExternalFlowPage(url: uri)),
    );
    if (mounted && _step?.flowId != null) await _fetchFlow(_step!.flowId!);
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    final step = _step;
    if (_ownsFlow &&
        step?.flowId != null &&
        step?.type != 'create_entry' &&
        step?.type != 'abort') {
      unawaited(_client?.cancelFlow(step!.flowId!, options: widget.options));
    }
    super.dispose();
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

class _ExternalFlowPage extends StatefulWidget {
  const _ExternalFlowPage({required this.url});
  final Uri url;
  @override
  State<_ExternalFlowPage> createState() => _ExternalFlowPageState();
}

class _ExternalFlowPageState extends State<_ExternalFlowPage> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final scheme = Uri.tryParse(request.url)?.scheme;
          return scheme == 'https' || scheme == 'http'
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
      ),
    )
    ..loadRequest(widget.url);
  @override
  Widget build(BuildContext context) => AppPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: Text(AppLocalizations.of(context).adminOptions),
    ),
    child: SafeArea(child: WebViewWidget(controller: _controller)),
  );
}
