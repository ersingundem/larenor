import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/legacy_remote_management_api.dart';
import '../domain/legacy_remote_models.dart';

/// The same active route owns edits; private learned names stay in Core storage.
class LegacyRemoteCommandEditorScreen extends StatefulWidget {
  const LegacyRemoteCommandEditorScreen({
    super.key,
    required this.api,
    required this.source,
    required this.commandLabel,
    required this.onSaved,
    required this.onCancel,
  });
  final LegacyRemoteCommandEditorApi api;
  final LegacyRemoteSourceBinding source;
  final String Function(LegacyRemoteCommandKey) commandLabel;
  final ValueChanged<LegacyRemoteSourceBinding> onSaved;
  final VoidCallback onCancel;

  @override
  State<LegacyRemoteCommandEditorScreen> createState() => _CommandEditorState();
}

class _CommandEditorState extends State<LegacyRemoteCommandEditorScreen> {
  final _name = TextEditingController();
  late LegacyRemoteSourceBinding _source;
  late LegacyRemoteCommandKey _selected;
  bool _busy = false, _failed = false;
  bool get _tr => Localizations.localeOf(context).languageCode == 'tr';
  @override
  void initState() {
    super.initState();
    _source = widget.source;
    _selected = _source.commandKeys.first;
  }

  Future<void> _choose() async {
    final key = await showCupertinoModalPopup<LegacyRemoteCommandKey>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(_tr ? 'Tuş seç' : 'Choose button'),
        actions: [
          for (final key in LegacyRemoteCommandKey.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, key),
              child: Text(widget.commandLabel(key)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(_tr ? 'Vazgeç' : 'Cancel'),
        ),
      ),
    );
    if (mounted && key != null) {
      setState(() {
        _selected = key;
        _name.clear();
        _failed = false;
      });
    }
  }

  Future<void> _update({bool remove = false}) async {
    if (_busy ||
        (!remove && _name.text.trim().isEmpty) ||
        (remove &&
            (!_source.commandKeys.contains(_selected) ||
                _source.commandKeys.length < 2))) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final value = await widget.api.updateSourceCommands(
        source: _source,
        upsert: remove ? {} : {_selected: _name.text.trim()},
        remove: remove ? {_selected} : {},
      );
      if (!mounted) return;
      setState(() {
        _source = value;
        _name.clear();
      });
      widget.onSaved(value);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ServiceRootScaffold(
    title: _source.name,
    slivers: [
      SliverToBoxAdapter(
        child: SettingsSection(
          header: Text(_tr ? 'Tuş eşleştirmeleri' : 'Button mappings'),
          footer: Text(
            _tr
                ? 'Komut adları Home Assistant içinde önceden öğrenilmiş olmalı. Diğer tuşlar korunur; kaydetmek IR sinyali göndermez. Son tuş silinemez.'
                : 'Command names must already be learned in Home Assistant. Other buttons are preserved; saving sends no IR signal. The last button cannot be removed.',
          ),
          children: [
            SettingsActionTile(
              buttonKey: const ValueKey('legacy-command-back'),
              leading: const Icon(CupertinoIcons.chevron_back),
              title: Text(_tr ? 'Geri dön' : 'Go back'),
              onTap: _busy ? null : widget.onCancel,
            ),
            for (final key in _source.commandKeys)
              SettingsActionTile(
                buttonKey: ValueKey('legacy-command-existing-${key.name}'),
                title: Text(widget.commandLabel(key)),
                leading: Icon(
                  _selected == key
                      ? CupertinoIcons.check_mark_circled
                      : CupertinoIcons.circle,
                ),
                additionalInfo: Text(_tr ? 'Kayıtlı' : 'Saved'),
                onTap: _busy
                    ? null
                    : () => setState(() {
                        _selected = key;
                        _name.clear();
                        _failed = false;
                      }),
              ),
            SettingsActionTile(
              buttonKey: const ValueKey('legacy-command-choose'),
              leading: const Icon(CupertinoIcons.square_grid_2x2),
              title: Text(
                _tr
                    ? 'Eklenecek veya değiştirilecek tuş'
                    : 'Button to add or update',
              ),
              additionalInfo: Text(widget.commandLabel(_selected)),
              onTap: _busy ? null : _choose,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Semantics(
                label: _tr ? 'Öğrenilmiş komut adı' : 'Learned command name',
                child: CupertinoTextField(
                  key: const ValueKey('legacy-command-name'),
                  controller: _name,
                  placeholder: _tr
                      ? 'Home Assistant komut adı'
                      : 'Home Assistant command name',
                  enabled: !_busy,
                  maxLength: 128,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
            SettingsActionTile(
              buttonKey: const ValueKey('legacy-command-save'),
              leading: _busy
                  ? const CupertinoActivityIndicator()
                  : const Icon(CupertinoIcons.checkmark_shield),
              title: Text(
                _tr
                    ? 'Eşleştirmeyi doğrula ve kaydet'
                    : 'Verify and save mapping',
              ),
              onTap: _busy || _name.text.trim().isEmpty ? null : _update,
            ),
            SettingsActionTile(
              buttonKey: const ValueKey('legacy-command-remove'),
              leading: const Icon(CupertinoIcons.minus_circle),
              title: Text(_tr ? 'Bu tuşu kaldır' : 'Remove this button'),
              onTap:
                  _busy ||
                      !_source.commandKeys.contains(_selected) ||
                      _source.commandKeys.length < 2
                  ? null
                  : () => _update(remove: true),
            ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _tr
                        ? 'Eşleştirme kaydedilemedi. Kaynağı yeniden yükleyin veya komut adını kontrol edin.'
                        : 'The mapping could not be saved. Reload the source or check the command name.',
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}
