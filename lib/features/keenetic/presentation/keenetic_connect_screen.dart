import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/keenetic_api_exception.dart';
import '../providers/keenetic_providers.dart';

class KeeneticConnectScreen extends ConsumerStatefulWidget {
  const KeeneticConnectScreen({super.key});

  @override
  ConsumerState<KeeneticConnectScreen> createState() =>
      _KeeneticConnectScreenState();
}

class _KeeneticConnectScreenState extends ConsumerState<KeeneticConnectScreen> {
  static const _defaultUrl = 'http://192.168.1.1';

  final _urlController = TextEditingController(text: _defaultUrl);
  final _userController = TextEditingController(text: 'admin');
  final _passwordController = TextEditingController();
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefillGatewayIp();
  }

  /// The router is almost always reachable at the device's default
  /// gateway — a much cheaper and more reliable "discovery" than sweeping
  /// the subnet, since there's exactly one gateway to check.
  Future<void> _prefillGatewayIp() async {
    try {
      final gateway = await NetworkInfo().getWifiGatewayIP();
      if (!mounted || gateway == null) return;
      if (_urlController.text != _defaultUrl) return;
      setState(() => _urlController.text = 'http://$gateway');
    } catch (_) {
      // Keep the manual default — nothing to prefill with.
    }
  }

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
      setState(
        () =>
            _error = AppLocalizations.of(context).keeneticErrorEnterUrlUsername,
      );
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ref
          .read(keeneticConnectionProvider.notifier)
          .signIn(
            baseUrl: url.endsWith('/') ? url.substring(0, url.length - 1) : url,
            username: username,
            password: password,
          );
      if (mounted) Navigator.of(context).pop();
    } on KeeneticApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(
        () => _error = AppLocalizations.of(context).keeneticErrorUnreachable,
      );
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Keenetic')),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 16),
                CupertinoListSection.insetGrouped(
                  footer: Text(
                    AppLocalizations.of(context).keeneticCredentialsHint,
                  ),
                  children: [
                    CupertinoTextFormFieldRow(
                      controller: _urlController,
                      prefix: Text(
                        AppLocalizations.of(context).connectUrlLabel,
                      ),
                      keyboardType: TextInputType.url,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _userController,
                      prefix: Text(AppLocalizations.of(context).mediaUserLabel),
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _passwordController,
                      prefix: Text(
                        AppLocalizations.of(context).mediaPasswordLabel,
                      ),
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
                      : Text(AppLocalizations.of(context).commonConnect),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
