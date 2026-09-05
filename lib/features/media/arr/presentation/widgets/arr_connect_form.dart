import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/direct_home_access.dart';
import '../../../hub/presentation/media_session_state.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../../shared/discovery/lan_discovery_section.dart';
import '../../../../../shared/discovery/lan_scanner.dart';
import '../../../../../shared/widgets/settings_section.dart';

/// Shared connect UI for Sonarr/Radarr/Lidarr/Readarr — identical shape
/// (URL + API key), just parameterized by title/hint/the actual sign-in
/// call/discovery signature.
class ArrConnectForm extends ConsumerStatefulWidget {
  const ArrConnectForm({
    super.key,
    required this.title,
    required this.urlHint,
    required this.onConnect,
    this.discoverySignature,
  });

  final String title;
  final String urlHint;
  final Future<void> Function(String baseUrl, String apiKey, bool Function() isCurrent) onConnect;
  final LanServiceSignature? discoverySignature;

  @override
  ConsumerState<ArrConnectForm> createState() => _ArrConnectFormState();
}

class _ArrConnectFormState extends MediaSessionState<ArrConnectForm> {
  late final _urlController = TextEditingController(text: widget.urlHint);
  final _keyController = TextEditingController();
  late final DirectHomeAccess _access = ref.read(directHomeAccessProvider);
  bool _visible = true;
  bool _connecting = false;
  String? _error;

  bool _current(int generation) =>
      sessionCurrent(generation) && _access.isCurrent &&
      TickerMode.of(context) && (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.of(context) &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (_visible && !visible) {
      sessionGeneration++;
      clearPendingInteraction();
    }
    _visible = visible;
  }

  @override
  void didUpdateWidget(covariant ArrConnectForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.onConnect, oldWidget.onConnect)) {
      sessionGeneration++;
      clearPendingInteraction();
    }
  }

  @override
  void clearPendingInteraction() {
    _urlController.clear();
    _keyController.clear();
    _connecting = false;
    _error = null;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _connect(int generation,
      Future<void> Function(String, String, bool Function()) connect) async {
    if (!_current(generation) || _connecting ||
        !identical(widget.onConnect, connect)) return;
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      setState(
        () => _error = AppLocalizations.of(context).mediaErrorEnterUrlApiKey,
      );
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await connect(
        url.endsWith('/') ? url.substring(0, url.length - 1) : url,
        key,
        () => _current(generation) && identical(widget.onConnect, connect),
      );
    } catch (_) {
      if (!_current(generation)) return;
      setState(
        () => _error = AppLocalizations.of(context).mediaErrorUnreachable,
      );
    } finally {
      if (_current(generation)) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(directHomeAccessProvider);
    final generation = sessionGeneration;
    final connect = widget.onConnect;
    if (!_access.isCurrent) {
      return CupertinoPageScaffold(child: Center(child:
        Text(AppLocalizations.of(context).mediaErrorUnreachable)));
    }
    final active = _current(generation);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(widget.title)),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 16),
                if (active && widget.discoverySignature != null)
                  LanDiscoverySection(
                    signature: widget.discoverySignature!,
                    onSelected: (url) {
                      if (_current(generation)) {
                        setState(() => _urlController.text = url);
                      }
                    },
                  ),
                SettingsSection(
                  footer: Text(
                    AppLocalizations.of(context).arrApiKeyHint(widget.title),
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
                      controller: _keyController,
                      prefix: Text(
                        AppLocalizations.of(context).mediaApiKeyLabel,
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
                  onPressed: _connecting || !active ? null : () => _connect(generation, connect),
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
