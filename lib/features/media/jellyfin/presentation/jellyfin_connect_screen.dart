import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/media_api_exception.dart';
import '../providers/jellyfin_providers.dart';

class JellyfinConnectScreen extends ConsumerStatefulWidget {
  const JellyfinConnectScreen({super.key});

  @override
  ConsumerState<JellyfinConnectScreen> createState() =>
      _JellyfinConnectScreenState();
}

class _JellyfinConnectScreenState extends ConsumerState<JellyfinConnectScreen> {
  final _urlController = TextEditingController(
    text: 'http://jellyfin.local:8096',
  );
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final url = _urlController.text.trim();
    final username = _userController.text.trim();
    final password = _passwordController.text;
    if (url.isEmpty || username.isEmpty) {
      setState(() => _error = 'Enter a server URL and username.');
      return;
    }

    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ref
          .read(jellyfinConnectionProvider.notifier)
          .signIn(
            baseUrl: url.endsWith('/') ? url.substring(0, url.length - 1) : url,
            username: username,
            password: password,
          );
      if (mounted) Navigator.of(context).pop();
    } on MediaApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Jellyfin')),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  children: [
                    CupertinoTextFormFieldRow(
                      controller: _urlController,
                      prefix: const Text('URL'),
                      placeholder: 'http://jellyfin.local:8096',
                      keyboardType: TextInputType.url,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _userController,
                      prefix: const Text('User'),
                      placeholder: 'Username',
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _passwordController,
                      prefix: const Text('Password'),
                      obscureText: true,
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: CupertinoColors.systemRed.resolveFrom(context),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                CupertinoButton.filled(
                  onPressed: _connecting ? null : _connect,
                  child: _connecting
                      ? const CupertinoActivityIndicator(
                          color: CupertinoColors.white,
                        )
                      : const Text('Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
