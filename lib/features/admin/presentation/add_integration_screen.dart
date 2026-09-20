import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/flow_schema_field.dart';
import '../data/models/flow_step.dart';
import '../providers/admin_providers.dart';
import 'widgets/dynamic_form_field.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import 'admin_session_state.dart';

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

class _AddIntegrationScreenState
    extends AdminSessionState<AddIntegrationScreen> {
  List<String>? _handlers;
  String _query = '';
  String? _handlersError;

  FlowStep? _step;
  final _formValues = <String, dynamic>{};
  int _formRevision = 0;
  bool _submitting = false;
  String? _stepError;
  Timer? _progressTimer;
  bool _ownsFlow = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !adminAuthorityCurrent) return;
      final generation = adminActionGeneration;
      if (widget.flowId != null) {
        _fetchFlow(widget.flowId!, generation);
      } else if (widget.handler != null) {
        _startFlow(widget.handler!, generation);
      } else {
        _loadHandlers(generation);
      }
    });
  }

  @override
  void adminSessionExpired() => _progressTimer?.cancel();

  Future<void> _loadHandlers(int generation) async {
    final client = adminClient;
    if (client == null || !adminActionCurrent(generation)) return;
    try {
      final handlers = await client.listFlowHandlers();
      if (adminActionCurrent(generation)) {
        setState(() {
          _handlers = handlers;
          _handlersError = null;
        });
      }
    } catch (e) {
      if (adminActionCurrent(generation)) {
        setState(() => _handlersError = e.toString());
      }
    }
  }

  Future<void> _startFlow(String handler, int generation) async {
    final client = adminClient;
    if (client == null || !adminActionCurrent(generation)) return;
    setState(() => _submitting = true);
    try {
      final step = await client.startFlow(
        handler,
        entryId: widget.entryId,
        options: widget.options,
      );
      _ownsFlow = true;
      if (!adminActionCurrent(generation)) {
        if (step.flowId != null) {
          await client.cancelFlow(step.flowId!, options: widget.options);
        }
        return;
      }
      _acceptStep(step, generation);
    } catch (e) {
      if (adminActionCurrent(generation)) {
        setState(() => _stepError = e.toString());
      }
    } finally {
      if (adminActionCurrent(generation)) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _submitStep(Map<String, dynamic> data, int generation) async {
    final client = adminClient;
    final flowId = _step?.flowId;
    if (client == null || flowId == null || !adminActionCurrent(generation)) {
      return;
    }

    setState(() => _submitting = true);
    try {
      final next = await client.submitFlowStep(
        flowId,
        data,
        options: widget.options,
      );
      if (!adminActionCurrent(generation)) return;
      _acceptStep(next, generation);
    } catch (e) {
      if (adminActionCurrent(generation)) {
        setState(() => _stepError = e.toString());
      }
    } finally {
      if (adminActionCurrent(generation)) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    watchAdminSession();
    final l10n = AppLocalizations.of(context);
    return ServiceRootScaffold(
      title: widget.options
          ? l10n.adminOptions
          : widget.entryId != null
          ? l10n.adminReconfigure
          : l10n.addIntegrationTitle,
      slivers: [
        SliverFillRemaining(
          child: SafeArea(top: false, child: _buildBody(context)),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!adminAuthorityCurrent) {
      return Center(
        child: Semantics(
          liveRegion: true,
          child: Text(l10n.adminEditorSessionChanged),
        ),
      );
    }
    final generation = adminActionGeneration;
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
                      minimumSize: const Size(48, 48),
                      onPressed: () => widget.flowId != null
                          ? _fetchFlow(widget.flowId!, generation)
                          : _startFlow(widget.handler!, generation),
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
                minimumSize: const Size(48, 48),
                onPressed: _submitting
                    ? null
                    : () => _fetchFlow(step.flowId!, generation),
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
                    minimumSize: const Size(48, 48),
                    onPressed: () => _openExternal(step.url!, generation),
                    child: Text(l10n.commonNext),
                  ),
                CupertinoButton(
                  minimumSize: const Size(48, 48),
                  onPressed: _submitting
                      ? null
                      : () => _fetchFlow(step.flowId!, generation),
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
    final generation = adminActionGeneration;
    if (_handlersError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.adminLoadError(_handlersError!)),
            CupertinoButton(
              minimumSize: const Size(48, 48),
              onPressed: () {
                setState(() => _handlersError = null);
                _loadHandlers(generation);
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
          child: SizedBox(
            height: 48,
            child: CupertinoSearchTextField(
              placeholder: l10n.addIntegrationSearchPlaceholder,
              onChanged: (value) => setState(() => _query = value),
            ),
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
          child: ListView(
            children: [
              if (filtered.isNotEmpty)
                SettingsSection(
                  header: Semantics(
                    key: const ValueKey('integration-list-header'),
                    header: true,
                    child: Text(l10n.addIntegrationTitle),
                  ),
                  children: [
                    for (final handler in filtered)
                      SettingsActionTile(
                        buttonKey: ValueKey('integration-handler-$handler'),
                        title: Text(handler),
                        onTap: _submitting
                            ? null
                            : () => _startFlow(handler, generation),
                      ),
                  ],
                ),
            ],
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
    final generation = adminActionGeneration;
    return ListView(
      children: [
        const SizedBox(height: 16),
        SettingsSection(
          header: step.title != null
              ? Semantics(header: true, child: Text(step.title!))
              : null,
          children: [
            for (final option in options)
              SettingsActionTile(
                buttonKey: ValueKey('integration-menu-$option'),
                title: Text(option),
                onTap: _submitting
                    ? null
                    : () => _submitStep({'next_step_id': option}, generation),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildForm(FlowStep step) {
    final generation = adminActionGeneration;
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
            minimumSize: const Size(48, 48),
            onPressed: _submitting
                ? null
                : () {
                    try {
                      _submitStep(
                        normalizeFlowValues(step.dataSchema, _formValues),
                        generation,
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

  void _acceptStep(FlowStep next, int generation) {
    if (!adminActionCurrent(generation)) return;
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
        () => _fetchFlow(next.flowId!, generation),
      );
    }
    if (next.type == 'create_entry' || next.type == 'abort') {
      ref.invalidate(configEntriesProvider);
    }
  }

  Future<void> _fetchFlow(String flowId, int generation) async {
    final client = adminClient;
    if (client == null || _submitting || !adminActionCurrent(generation)) {
      return;
    }
    setState(() => _submitting = true);
    try {
      final next = await client.getFlow(flowId, options: widget.options);
      if (adminActionCurrent(generation)) _acceptStep(next, generation);
    } catch (error) {
      if (adminActionCurrent(generation)) {
        setState(() => _stepError = error.toString());
      }
    } finally {
      if (adminActionCurrent(generation)) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _openExternal(String url, int generation) async {
    if (!adminActionCurrent(generation)) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !['https', 'http'].contains(uri.scheme)) return;
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(builder: (_) => _ExternalFlowPage(url: uri)),
    );
    if (adminAuthorityCurrent && _step?.flowId != null) {
      setState(() {});
      await _fetchFlow(_step!.flowId!, adminActionGeneration);
    }
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    final step = _step;
    if (_ownsFlow &&
        step?.flowId != null &&
        step?.type != 'create_entry' &&
        step?.type != 'abort') {
      unawaited(
        adminClient?.cancelFlow(step!.flowId!, options: widget.options),
      );
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
              minimumSize: const Size(48, 48),
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
