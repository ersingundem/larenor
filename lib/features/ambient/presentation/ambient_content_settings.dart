import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../settings/presentation/settings_file_dialog.dart';
import '../domain/ambient_content.dart';
import '../providers/ambient_providers.dart';

class AmbientContentSettings extends ConsumerStatefulWidget {
  const AmbientContentSettings({super.key, this.runFileDialog});
  final SettingsFileDialogRunner? runFileDialog;

  @override
  ConsumerState<AmbientContentSettings> createState() =>
      _AmbientContentSettingsState();
}

class _AmbientContentSettingsState
    extends ConsumerState<AmbientContentSettings> {
  late final AppLifecycleListener _lifecycle;
  AppInteractionController? _interaction;
  int _generation = 0;
  bool _foreground = true, _busy = false, _dialog = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final next = state == AppLifecycleState.resumed;
        if (_foreground && !next) _generation++;
        _foreground = next;
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (!identical(next, _interaction)) {
      _interaction?.removeListener(_interactionChanged);
      _interaction = next?..addListener(_interactionChanged);
    }
  }

  void _interactionChanged() {
    if (_interaction?.active == false) _generation++;
  }

  bool get _current =>
      mounted &&
      _foreground &&
      (_interaction?.active ?? true) &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent != false || _dialog);

  Future<void> _pick(AmbientContentKind kind) async {
    if (!_current || _busy) return;
    final initialGeneration = _generation;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final access = ref.read(ambientContentFileAccessProvider);
      Future<Stream<List<int>>?> action() => access.pick(kind);
      final stream = widget.runFileDialog == null
          ? await action()
          : await widget.runFileDialog!(action);
      if (stream == null ||
          !_current ||
          (widget.runFileDialog == null && initialGeneration != _generation)) {
        return;
      }
      final acceptedGeneration = _generation;
      await ref
          .read(ambientContentRepositoryProvider)
          .importLocal(
            kind,
            stream,
            isCurrent: () => _current && acceptedGeneration == _generation,
          );
      if (_current && acceptedGeneration == _generation) {
        ref.invalidate(ambientContentLibraryProvider);
      }
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addWeb() async {
    if (!_current || _busy) return;
    final generation = _generation;
    final controller = TextEditingController();
    var confirmed = false;
    _dialog = true;
    try {
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) {
          final l10n = AppLocalizations.of(dialogContext);
          void confirm() {
            if (!_current ||
                generation != _generation ||
                !dialogContext.mounted ||
                ModalRoute.of(dialogContext)?.isCurrent != true) {
              return;
            }
            confirmed = true;
            Navigator.pop(dialogContext);
          }

          return CupertinoAlertDialog(
            title: Text(l10n.ambientAddWeb),
            content: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: CupertinoTextField(
                key: const ValueKey('ambient-web-url'),
                controller: controller,
                placeholder: l10n.ambientWebAddress,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                onSubmitted: (_) => confirm(),
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l10n.commonCancel),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: confirm,
                child: Text(l10n.ambientWebConfirm),
              ),
            ],
          );
        },
      );
    } finally {
      _dialog = false;
    }
    final value = controller.text.trim();
    controller.dispose();
    if (!confirmed || !_current || generation != _generation) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref
          .read(ambientContentRepositoryProvider)
          .addWeb(
            value,
            isCurrent: () => _current && generation == _generation,
          );
      if (_current && generation == _generation) {
        ref.invalidate(ambientContentLibraryProvider);
      }
    } catch (error) {
      _error(error, web: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _move(
    List<AmbientContent> expected,
    int index,
    int delta,
  ) async {
    final target = index + delta;
    if (!_current || _busy || target < 0 || target >= expected.length) return;
    final next = List<AmbientContent>.of(expected);
    next.insert(target, next.removeAt(index));
    await _replace(expected, next);
  }

  Future<void> _remove(List<AmbientContent> expected, int index) async {
    if (!_current || _busy) return;
    final generation = _generation;
    var confirmed = false;
    _dialog = true;
    try {
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) {
          final l10n = AppLocalizations.of(dialogContext);
          return CupertinoAlertDialog(
            content: Text(l10n.ambientContentRemoveMessage),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l10n.commonCancel),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () {
                  if (_current &&
                      generation == _generation &&
                      dialogContext.mounted &&
                      ModalRoute.of(dialogContext)?.isCurrent == true) {
                    confirmed = true;
                    Navigator.pop(dialogContext);
                  }
                },
                child: Text(l10n.commonRemove),
              ),
            ],
          );
        },
      );
    } finally {
      _dialog = false;
    }
    if (!confirmed || !_current || generation != _generation) return;
    await _replace(
      expected,
      List<AmbientContent>.of(expected)..removeAt(index),
    );
  }

  Future<void> _replace(
    List<AmbientContent> expected,
    List<AmbientContent> next,
  ) async {
    final generation = _generation;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref
          .read(ambientContentRepositoryProvider)
          .replaceOrder(
            next,
            expected: expected,
            isCurrent: () => _current && generation == _generation,
          );
      if (_current && generation == _generation) {
        ref.invalidate(ambientContentLibraryProvider);
      }
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _error(Object error, {bool web = false}) {
    if (!_current) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _message = web
          ? l10n.ambientWebInvalid
          : error is AmbientContentException && error.limit
          ? l10n.ambientContentLimit
          : l10n.ambientContentFailed;
    });
  }

  String _title(AppLocalizations l10n, AmbientContent item, int index) =>
      switch (item.kind) {
        AmbientContentKind.video => l10n.ambientContentVideo(index + 1),
        AmbientContentKind.pdf => l10n.ambientContentPdf(index + 1),
        AmbientContentKind.web => l10n.ambientContentWeb(index + 1),
      };

  @override
  void dispose() {
    _generation++;
    _interaction?.removeListener(_interactionChanged);
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final reading = ref.watch(ambientContentLibraryProvider);
    final items = reading.value;
    final available = _current && !_busy;
    return SettingsSection(
      header: Text(l10n.ambientContent),
      footer: Text(l10n.ambientContentHint),
      children: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: CupertinoActivityIndicator(),
          ),
        if (_message != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_message!),
            ),
          ),
        SettingsActionTile(
          buttonKey: const ValueKey('ambient-add-video'),
          leading: const Icon(CupertinoIcons.film),
          title: Text(l10n.ambientAddVideo),
          onTap: available ? () => _pick(AmbientContentKind.video) : null,
        ),
        SettingsActionTile(
          buttonKey: const ValueKey('ambient-add-pdf'),
          leading: const Icon(CupertinoIcons.doc),
          title: Text(l10n.ambientAddPdf),
          onTap: available ? () => _pick(AmbientContentKind.pdf) : null,
        ),
        SettingsActionTile(
          buttonKey: const ValueKey('ambient-add-web'),
          leading: const Icon(CupertinoIcons.globe),
          title: Text(l10n.ambientAddWeb),
          onTap: available ? _addWeb : null,
        ),
        if (reading.isLoading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: CupertinoActivityIndicator(),
          )
        else if (reading.hasError)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.ambientContentFailed),
          )
        else if (items?.isEmpty == true)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.ambientContentEmpty),
          )
        else if (items != null)
          for (var index = 0; index < items.length; index++)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_title(l10n, items[index], index)),
                  if (items[index].webUrl case final url?)
                    Text(
                      Uri.parse(url).host,
                      style: TextStyle(
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      CupertinoButton(
                        minimumSize: const Size(48, 48),
                        onPressed: available && index > 0
                            ? () => _move(items, index, -1)
                            : null,
                        child: Text(l10n.dashboardMoveUp),
                      ),
                      CupertinoButton(
                        minimumSize: const Size(48, 48),
                        onPressed: available && index < items.length - 1
                            ? () => _move(items, index, 1)
                            : null,
                        child: Text(l10n.dashboardMoveDown),
                      ),
                      CupertinoButton(
                        minimumSize: const Size(48, 48),
                        onPressed: available
                            ? () => _remove(items, index)
                            : null,
                        child: Text(l10n.commonRemove),
                      ),
                    ],
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
