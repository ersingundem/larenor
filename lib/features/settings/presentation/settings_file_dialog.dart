import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/pin_lock_store.dart';

/// Holds only a trusted native file dialog open across Settings relocking.
/// The gate must reauthenticate before returning the selected ciphertext.
typedef SettingsFileDialogRunner = Future<T?> Function<T>(
  Future<T?> Function() operation,
);

Future<bool> reauthenticateSettingsFileDialog(
  BuildContext context,
  PinLockStore store,
) async =>
    await showCupertinoDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _FileDialogPinPrompt(store: store),
    ) ??
    false;

class _FileDialogPinPrompt extends StatefulWidget {
  const _FileDialogPinPrompt({required this.store});
  final PinLockStore store;

  @override
  State<_FileDialogPinPrompt> createState() => _FileDialogPinPromptState();
}

class _FileDialogPinPromptState extends State<_FileDialogPinPrompt>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  int _generation = 0;
  bool _checking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _generation++;
      _controller.clear();
      setState(() {
        _checking = false;
        _error = null;
      });
    }
  }

  Future<void> _submit() async {
    if (_checking) return;
    final generation = _generation;
    final l10n = AppLocalizations.of(context);
    setState(() => _checking = true);
    try {
      final result = await widget.store.verify(_controller.text);
      if (!mounted || generation != _generation) return;
      _controller.clear();
      if (result.accepted) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _error = result.retryAfter > Duration.zero
            ? l10n.settingsGateRetryAfter(
                (result.retryAfter.inMilliseconds / 1000).ceil(),
              )
            : l10n.settingsGateIncorrectPin;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = l10n.settingsGateStorageError);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _checking = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return CupertinoAlertDialog(
      title: Text(l10n.settingsScreenTitle),
      content: Column(
        children: [
          const SizedBox(height: 12),
          CupertinoTextField(
            key: const ValueKey('backup-reauth-pin'),
            controller: _controller,
            obscureText: true,
            autofocus: true,
            enabled: !_checking,
            keyboardType: TextInputType.number,
            enableSuggestions: false,
            autocorrect: false,
            placeholder: l10n.settingsGatePinPlaceholder,
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: CupertinoColors.systemRed),
            ),
          ],
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        CupertinoDialogAction(
          onPressed: _checking ? null : _submit,
          child: _checking
              ? const CupertinoActivityIndicator()
              : Text(l10n.settingsGateUnlockButton),
        ),
      ],
    );
  }
}
