import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/discovery/lan_discovery_section.dart';
import '../../../shared/discovery/service_signatures.dart';
import '../data/proxmox_api_exception.dart';
import '../providers/proxmox_providers.dart';
import '../../../shared/widgets/settings_section.dart';

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
    final input = _hostController.text.trim();
    final address = Uri.tryParse(
      input.contains('://') ? input : 'https://$input',
    );
    final host = address?.host ?? '';
    final port = address?.hasPort == true
        ? address!.port
        : int.tryParse(_portController.text.trim());
    final realm = _realmController.text.trim();
    final username = _userController.text.trim();
    final password = _passwordController.text;
    if (host.isEmpty ||
        address?.scheme != 'https' ||
        address!.userInfo.isNotEmpty ||
        address.hasQuery ||
        address.hasFragment ||
        (address.path.isNotEmpty && address.path != '/') ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        realm.isEmpty ||
        username.isEmpty ||
        password.isEmpty) {
      setState(
        () => _error = AppLocalizations.of(context).proxmoxErrorEnterFields,
      );
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
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _error = AppLocalizations.of(context).mediaErrorUnreachable,
      );
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
                SettingsSection(
                  children: [
                    CupertinoTextFormFieldRow(
                      controller: _hostController,
                      prefix: Text(
                        AppLocalizations.of(context).proxmoxHostLabel,
                      ),
                      placeholder: 'proxmox.local',
                      keyboardType: TextInputType.url,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _portController,
                      prefix: Text(
                        AppLocalizations.of(context).proxmoxPortLabel,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    CupertinoTextFormFieldRow(
                      controller: _realmController,
                      prefix: Text(
                        AppLocalizations.of(context).proxmoxRealmLabel,
                      ),
                      placeholder: 'pam',
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
                SettingsSection(
                  footer: Text(
                    AppLocalizations.of(context).proxmoxSelfSignedHint,
                  ),
                  children: [
                    CupertinoListTile(
                      title: Text(
                        AppLocalizations.of(context).proxmoxAllowSelfSigned,
                      ),
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
