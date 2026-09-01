import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/discovery/lan_discovery_section.dart';
import '../../../shared/discovery/service_signatures.dart';
import '../data/proxmox_api_exception.dart';
import '../providers/proxmox_providers.dart';

class ProxmoxConnectScreen extends ConsumerStatefulWidget {
  const ProxmoxConnectScreen({super.key});

  @override
  ConsumerState<ProxmoxConnectScreen> createState() =>
      _ProxmoxConnectScreenState();
}

class _ProxmoxConnectScreenState extends ConsumerState<ProxmoxConnectScreen> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8006');
  final _realmController = TextEditingController(text: 'pam');
  final _userController = TextEditingController(text: 'root');
  final _passwordController = TextEditingController();
  bool _allowSelfSigned = true;
  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _realmController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _selectDiscovered(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null) return;
    setState(() {
      _hostController.text = uri.host;
      if (uri.hasPort) _portController.text = uri.port.toString();
    });
  }

  Future<void> _connect() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 8006;
    final realm = _realmController.text.trim();
    final username = _userController.text.trim();
    final password = _passwordController.text;
    if (host.isEmpty || realm.isEmpty || username.isEmpty) {
      setState(() => _error = 'Enter a host, realm, and username.');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ref
          .read(proxmoxConnectionProvider.notifier)
          .signIn(
            host: host,
            port: port,
            username: username,
            realm: realm,
            password: password,
            allowSelfSigned: _allowSelfSigned,
          );
      if (mounted) Navigator.of(context).pop();
    } on ProxmoxApiException catch (e) {
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
      navigationBar: const CupertinoNavigationBar(middle: Text('Proxmox VE')),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 16),
                LanDiscoverySection(
                  signature: ServiceSignatures.proxmox,
                  onSelected: _selectDiscovered,
                ),
                CupertinoListSection.insetGrouped(
                  children: [
                    CupertinoTextFormFieldRow(
                      controller: _hostController,
                      prefix: const Text('Host'),
                      placeholder: 'proxmox.local',
                      keyboardType: TextInputType.url,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _portController,
                      prefix: const Text('Port'),
                      keyboardType: TextInputType.number,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _realmController,
                      prefix: const Text('Realm'),
                      placeholder: 'pam',
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _userController,
                      prefix: const Text('User'),
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _passwordController,
                      prefix: const Text('Password'),
                      obscureText: true,
                    ),
                  ],
                ),
                CupertinoListSection.insetGrouped(
                  footer: const Text(
                    'Proxmox uses a self-signed certificate by default on a '
                    'fresh install. Turn this off if you installed a trusted '
                    'certificate.',
                  ),
                  children: [
                    CupertinoListTile(
                      title: const Text('Allow self-signed certificate'),
                      trailing: CupertinoSwitch(
                        value: _allowSelfSigned,
                        onChanged: (value) =>
                            setState(() => _allowSelfSigned = value),
                      ),
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
