import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../data/server_account_controller.dart';
import '../../domain/server_models.dart';
import '../../services/domain/server_service_models.dart';
import '../data/server_component_egress_controller.dart';
import '../domain/server_component_egress_models.dart';

final class ServerComponentEgressDialog extends StatefulWidget {
  const ServerComponentEgressDialog({
    required this.account,
    required this.service,
    required this.current,
    super.key,
  });

  final ServerAccountController account;
  final ServerService service;
  final bool Function() current;

  @override
  State<ServerComponentEgressDialog> createState() =>
      _ServerComponentEgressDialogState();
}

class _ServerComponentEgressDialogState
    extends State<ServerComponentEgressDialog> {
  late final ServerComponentEgressController _controller;
  final _addresses = TextEditingController();
  String? _draftFailure;

  bool get _current => mounted && widget.current();

  @override
  void initState() {
    super.initState();
    _controller = ServerComponentEgressController(
      widget.account,
      widget.service,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!_current || _controller.busy) return;
    await _controller.load(current: () => _current);
    if (!_current) return;
    final grants = _controller.value?.policy.grants ?? const [];
    _addresses.text = grants.isEmpty
        ? ''
        : grants.single.addresses.map((value) => value.address).join('\n');
  }

  Future<void> _save() async {
    if (!_current || _controller.busy || _controller.value == null) return;
    final ServerComponentEgressGrant grant;
    try {
      grant = ServerComponentEgressGrant.fromEndpoint(
        widget.service.baseUrl,
        _addresses.text.split(RegExp(r'[\s,;]+')),
      );
    } on LarenorServerException {
      setState(() => _draftFailure = 'invalid_request');
      return;
    }
    setState(() => _draftFailure = null);
    await _controller.replace(grant: grant, current: () => _current);
  }

  Future<void> _disable() async {
    if (!_current || _controller.busy || _controller.value == null) return;
    setState(() => _draftFailure = null);
    await _controller.replace(current: () => _current);
    if (_current && _controller.failure == null) _addresses.clear();
  }

  String _failure(AppLocalizations l10n) => switch (_draftFailure ??
      _controller.failure) {
    'invalid_request' => l10n.serverEgressInvalid,
    'revision_conflict' || 'conflict' => l10n.serverEgressConflict,
    'unauthorized' => l10n.serverFailureAuthentication,
    'forbidden' || 'password_change_required' => l10n.serverFailurePermission,
    _ =>
      _controller.needsRefresh
          ? l10n.serverEgressUncertain
          : l10n.serverEgressFailed,
  };

  @override
  void dispose() {
    _addresses.clear();
    _addresses.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: CupertinoPopupSurface(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620, maxHeight: 820),
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                final policy = _controller.value?.policy;
                final failure = _draftFailure ?? _controller.failure;
                final grant = policy?.grants.firstOrNull;
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          l10n.serverEgressTitle,
                          style: AppText.title2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(widget.service.name, style: AppText.headline),
                      Text(l10n.serverEgressIntro),
                      const SizedBox(height: 16),
                      if (_controller.busy && policy == null)
                        const Center(child: CupertinoActivityIndicator()),
                      if (policy != null) ...[
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            grant == null
                                ? l10n.serverEgressBlocked
                                : l10n.serverEgressAllowed(
                                    grant.addresses.length,
                                  ),
                            style: AppText.headline,
                          ),
                        ),
                        Text(l10n.serverEgressRevision(policy.revision)),
                        Text(
                          l10n.serverEgressAudit(
                            _controller.value!.audit.length,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.serverEgressAddresses,
                          style: AppText.subhead,
                        ),
                        const SizedBox(height: 6),
                        CupertinoTextField(
                          key: const ValueKey('egress-addresses'),
                          controller: _addresses,
                          enabled:
                              !_controller.busy && !_controller.needsRefresh,
                          minLines: 4,
                          maxLines: 8,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          placeholder: l10n.serverEgressAddressesHint,
                          onChanged: (_) {
                            if (_draftFailure != null) {
                              setState(() => _draftFailure = null);
                            }
                          },
                        ),
                      ],
                      if (failure != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(_failure(l10n)),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.end,
                        children: [
                          _action(
                            key: const ValueKey('egress-refresh'),
                            label: l10n.commonRefresh,
                            onPressed: _controller.busy ? null : _load,
                          ),
                          if (grant != null)
                            _action(
                              key: const ValueKey('egress-disable'),
                              label: l10n.serverEgressDisable,
                              onPressed:
                                  _controller.busy || _controller.needsRefresh
                                  ? null
                                  : _disable,
                            ),
                          _action(
                            key: const ValueKey('egress-save'),
                            label: l10n.commonSave,
                            onPressed:
                                policy == null ||
                                    _controller.busy ||
                                    _controller.needsRefresh
                                ? null
                                : _save,
                          ),
                          _action(
                            key: const ValueKey('egress-close'),
                            label: l10n.commonClose,
                            onPressed: () {
                              if (_current) Navigator.of(context).pop();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _action({
    required Key key,
    required String label,
    required VoidCallback? onPressed,
  }) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 96, minHeight: 48),
    child: CupertinoButton(
      key: key,
      onPressed: onPressed,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(label),
    ),
  );
}
