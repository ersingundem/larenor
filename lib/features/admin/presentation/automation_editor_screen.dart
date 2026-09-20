import 'dart:convert';

import 'package:flutter/cupertino.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../providers/admin_providers.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_section.dart';
import 'admin_session_state.dart';

/// Raw JSON editor for an automation's trigger/condition/action config.
/// Used for both editing an existing automation (pass [automationId]) and
/// creating a new one (leave it null) — a visual trigger/condition/action
/// builder is a separate, much larger project deferred to a later phase.
class AutomationEditorScreen extends ConsumerStatefulWidget {
  const AutomationEditorScreen({
    super.key,
    this.automationId,
    this.initialConfig,
  });

  final String? automationId;
  final Map<String, dynamic>? initialConfig;

  @override
  ConsumerState<AutomationEditorScreen> createState() =>
      _AutomationEditorScreenState();
}

class _AutomationEditorScreenState
    extends AdminSessionState<AutomationEditorScreen> {
  static const _encoder = JsonEncoder.withIndent('  ');

  late final TextEditingController _controller;
  late final String _editingId;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.automationId == null;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _editingId =
        widget.automationId ?? DateTime.now().microsecondsSinceEpoch.toString();

    if (_isNew) {
      _controller.text = _encoder.convert(
        widget.initialConfig ??
            {
              'alias': 'New automation',
              'triggers': <dynamic>[],
              'conditions': <dynamic>[],
              'actions': <dynamic>[],
            },
      );
      _loading = false;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && adminAuthorityCurrent) {
          _loadExisting(adminActionGeneration);
        }
      });
    }
  }

  Future<void> _loadExisting(int generation) async {
    final client = adminClient;
    if (client == null || !adminActionCurrent(generation)) return;
    try {
      final config = await client.getAutomationConfig(_editingId);
      if (!mounted || !adminActionCurrent(generation)) return;
      _controller.text = _encoder.convert(config);
    } catch (e) {
      if (adminActionCurrent(generation)) {
        setState(
          () =>
              _error = AppLocalizations.of(context)
                  .adminLoadError(e.toString()),
        );
      }
    } finally {
      if (adminActionCurrent(generation)) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _save(int generation) async {
    final client = adminClient;
    if (client == null || !adminActionCurrent(generation)) return;

    final Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(_controller.text) as Map<String, dynamic>;
    } catch (e) {
      if (!adminActionCurrent(generation)) return;
      setState(
        () =>
            _error = AppLocalizations.of(context)
                .automationEditorInvalidJson(e.toString()),
      );
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      parsed['id'] = _editingId;
      await client.saveAutomationConfig(_editingId, parsed);
      if (!mounted || !adminActionCurrent(generation)) return;
      ref.invalidate(automationsProvider);
      Navigator.of(context).pop();
    } catch (e) {
      if (!adminActionCurrent(generation)) return;
      setState(
        () =>
            _error = AppLocalizations.of(context)
                .automationEditorSaveError(e.toString()),
      );
    } finally {
      if (adminActionCurrent(generation)) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _delete(int generation) async {
    final client = adminClient;
    if (client == null || !adminActionCurrent(generation)) return;

    var confirmed = false;
    final route = CupertinoDialogRoute<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(
          AppLocalizations.of(dialogContext).automationEditorDeleteTitle,
        ),
        content: Text(
          AppLocalizations.of(dialogContext).automationEditorDeleteMessage,
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(AppLocalizations.of(dialogContext).commonCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              if (dialogContext.mounted &&
                  ModalRoute.of(dialogContext)?.isCurrent == true &&
                  adminAuthorityCurrent) {
                confirmed = true;
              }
              if (dialogContext.mounted &&
                  ModalRoute.of(dialogContext)?.isCurrent == true) {
                Navigator.pop(dialogContext);
              }
            },
            child: Text(AppLocalizations.of(dialogContext).commonDelete),
          ),
        ],
      ),
    );
    await Navigator.of(context).push(route);
    await route.completed;
    if (!confirmed || !adminAuthorityCurrent) return;

    setState(() => _saving = true);
    try {
      await client.deleteAutomationConfig(_editingId);
      if (!mounted || !adminAuthorityCurrent) return;
      ref.invalidate(automationsProvider);
      Navigator.of(context).pop();
    } catch (e) {
      if (!adminAuthorityCurrent) return;
      setState(() {
        _error = AppLocalizations.of(context)
            .automationEditorDeleteError(e.toString());
        _saving = false;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchAdminSession();
    final l10n = AppLocalizations.of(context);
    final title = _isNew
        ? l10n.automationEditorNewTitle
        : l10n.automationEditorEditTitle;
    final generation = adminActionGeneration;
    final actionsEnabled =
        !_saving && !_loading && adminActionCurrent(generation);
    final editorHeight = (MediaQuery.sizeOf(context).height - 240).clamp(
      320.0,
      840.0,
    );
    return ServiceRootScaffold(
      title: title,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_isNew)
            Semantics(
              key: const ValueKey('automation-delete-action'),
              button: true,
              enabled: actionsEnabled,
              label: l10n.commonDelete,
              child: CupertinoButton(
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                onPressed: actionsEnabled ? () => _delete(generation) : null,
                child: Icon(
                  CupertinoIcons.delete,
                  color: CupertinoColors.destructiveRed.resolveFrom(context),
                ),
              ),
            ),
          Semantics(
            key: const ValueKey('automation-save-action'),
            button: true,
            enabled: actionsEnabled,
            label: l10n.commonSave,
            child: CupertinoButton(
              minimumSize: const Size(48, 48),
              padding: EdgeInsets.zero,
              onPressed: actionsEnabled ? () => _save(generation) : null,
              child: _saving
                  ? const CupertinoActivityIndicator()
                  : Text(l10n.commonSave),
            ),
          ),
        ],
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
          const SliverFilledMessage(child: CupertinoActivityIndicator())
        else ...[
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 20, 0),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    key: const ValueKey('automation-error-message'),
                    style: TextStyle(
                      color: CupertinoColors.systemRed.resolveFrom(context),
                    ),
                  ),
                ),
              ),
            ),
          SliverSafeArea(
            top: false,
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 16),
                SettingsSection(
                  header: Semantics(
                    key: const ValueKey('automation-json-header'),
                    header: true,
                    child: Text(title),
                  ),
                  children: [
                    SizedBox(
                      height: editorHeight,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: CupertinoTextField(
                          key: const ValueKey('automation-json-editor'),
                          controller: _controller,
                          readOnly: !actionsEnabled,
                          maxLines: null,
                          expands: true,
                          keyboardType: TextInputType.multiline,
                          textAlignVertical: TextAlignVertical.top,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: AppText.footnote.fontSize,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: CupertinoColors.separator.resolveFrom(
                                context,
                              ),
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ]),
            ),
          ),
        ],
      ],
    );
  }
}
