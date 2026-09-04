import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../providers/admin_providers.dart';

/// Raw JSON editor for an automation's trigger/condition/action config.
/// Used for both editing an existing automation (pass [automationId]) and
/// creating a new one (leave it null) — a visual trigger/condition/action
/// builder is a separate, much larger project deferred to a later phase.
class AutomationEditorScreen extends ConsumerStatefulWidget {
  const AutomationEditorScreen({super.key, this.automationId});

  final String? automationId;

  @override
  ConsumerState<AutomationEditorScreen> createState() =>
      _AutomationEditorScreenState();
}

class _AutomationEditorScreenState
    extends ConsumerState<AutomationEditorScreen> {
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
      _controller.text = _encoder.convert({
        'alias': 'New automation',
        'triggers': <dynamic>[],
        'conditions': <dynamic>[],
        'actions': <dynamic>[],
      });
      _loading = false;
    } else {
      _loadExisting();
    }
  }

  Future<void> _loadExisting() async {
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;
    try {
      final config = await client.getAutomationConfig(_editingId);
      _controller.text = _encoder.convert(config);
    } catch (e) {
      if (mounted) {
        _error = AppLocalizations.of(context).adminLoadError(e.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;

    final Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(_controller.text) as Map<String, dynamic>;
    } catch (e) {
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
      await client.saveAutomationConfig(_editingId, parsed);
      ref.invalidate(automationsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(
        () =>
            _error = AppLocalizations.of(context)
                .automationEditorSaveError(e.toString()),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final client = ref.read(haAdminClientProvider);
    if (client == null) return;

    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(AppLocalizations.of(context).automationEditorDeleteTitle),
        content: Text(
          AppLocalizations.of(context).automationEditorDeleteMessage,
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context).commonCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context).commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _saving = true);
    try {
      await client.deleteAutomationConfig(_editingId);
      ref.invalidate(automationsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
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
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          _isNew
              ? AppLocalizations.of(context).automationEditorNewTitle
              : AppLocalizations.of(context).automationEditorEditTitle,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_isNew)
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _saving ? null : _delete,
                child: Icon(
                  CupertinoIcons.delete,
                  color: CupertinoColors.destructiveRed.resolveFrom(context),
                ),
              ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const CupertinoActivityIndicator()
                  : Text(AppLocalizations.of(context).commonSave),
            ),
          ],
        ),
      ),
      child: SafeArea(
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : Column(
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: CupertinoColors.systemRed.resolveFrom(context),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: CupertinoTextField(
                        controller: _controller,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
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
      ),
    );
  }
}
