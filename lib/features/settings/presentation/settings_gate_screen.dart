import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/settings_providers.dart';
import 'settings_screen.dart';

/// Gates access to [SettingsScreen] behind a PIN, if one has been set —
/// protects the connection config and admin panel from casual tampering on
/// a shared wall-mounted tablet. No PIN set (the default) means unlocked.
class SettingsGateScreen extends ConsumerStatefulWidget {
  const SettingsGateScreen({super.key});

  @override
  ConsumerState<SettingsGateScreen> createState() => _SettingsGateScreenState();
}

class _SettingsGateScreenState extends ConsumerState<SettingsGateScreen> {
  final _controller = TextEditingController();
  bool _unlocked = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pinAsync = ref.watch(pinLockProvider);

    return pinAsync.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, _) =>
          CupertinoPageScaffold(child: Center(child: Text('$error'))),
      data: (pin) {
        if (pin == null || _unlocked) return const SettingsScreen();
        return _buildPinEntry(context, pin);
      },
    );
  }

  Widget _buildPinEntry(BuildContext context, String pin) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Settings')),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.lock_fill,
                    size: 40,
                    color: CupertinoTheme.of(context).primaryColor,
                  ),
                  const SizedBox(height: 16),
                  CupertinoTextField(
                    controller: _controller,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    autofocus: true,
                    placeholder: 'PIN',
                    onSubmitted: (_) => _submit(pin),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: CupertinoColors.systemRed.resolveFrom(context),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  CupertinoButton.filled(
                    onPressed: () => _submit(pin),
                    child: const Text('Unlock'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _submit(String pin) {
    if (_controller.text == pin) {
      setState(() {
        _unlocked = true;
        _error = null;
      });
    } else {
      setState(() => _error = 'Incorrect PIN');
      _controller.clear();
    }
  }
}
