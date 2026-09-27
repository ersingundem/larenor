import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_music_provider_setup_controller.dart';
import '../domain/server_music_provider_setup_models.dart';

class ServerMusicProviderSetupScreen extends ConsumerStatefulWidget {
  const ServerMusicProviderSetupScreen({
    super.key,
    required this.installationId,
    required this.installationRevision,
    this.controller,
    this.openExternal,
  });

  final String installationId;
  final int installationRevision;

  @visibleForTesting
  final ServerMusicProviderSetupController? controller;

  @visibleForTesting
  final Future<bool> Function(Uri uri)? openExternal;

  @override
  ConsumerState<ServerMusicProviderSetupScreen> createState() =>
      _ServerMusicProviderSetupScreenState();
}

class _ServerMusicProviderSetupScreenState
    extends ConsumerState<ServerMusicProviderSetupScreen>
    with WidgetsBindingObserver {
  late final ServerAccountController _account;
  late final ServerMusicProviderSetupController _controller;
  late final int _accountEpoch;
  late final bool _ownsController;
  late final Future<bool> Function(Uri) _openExternal;
  ValueListenable<TickerModeData>? _ticker;
  final Map<String, TextEditingController> _textFields = {};
  final Map<String, bool> _booleanFields = {};
  String? _fieldRevision;
  String? _setupRevision;
  bool _visible = true;
  bool _resumed = true;
  bool _retired = false;
  bool _externalOpened = false;
  bool _externalFailed = false;
  bool _formIncomplete = false;

  bool get _active =>
      mounted &&
      !_retired &&
      _visible &&
      _resumed &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _controller =
        widget.controller ??
        ServerMusicProviderSetupController(
          _account,
          installationId: widget.installationId,
          installationRevision: widget.installationRevision,
        );
    _ownsController = widget.controller == null;
    _openExternal =
        widget.openExternal ??
        (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
    _account.addListener(_accountChanged);
    _controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final current = _capture();
      if (current()) {
        unawaited(_controller.loadCapabilities(current: current));
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = ticker;
      _visible = ticker.value.enabled;
      ticker.addListener(_visibilityChanged);
    }
  }

  void _visibilityChanged() {
    final visible = _ticker?.value.enabled ?? true;
    if (_visible == visible) return;
    _visible = visible;
    if (!visible) {
      _clearInputs();
    } else {
      _refreshAfterReturn();
    }
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) ||
        _account.session?.user.canAdminister != true) {
      _retired = true;
      _clearInputs();
      _controller.invalidate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_resumed == resumed) return;
    _resumed = resumed;
    if (!resumed) {
      _clearInputs();
    } else {
      _refreshAfterReturn();
    }
  }

  void _refreshAfterReturn() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final current = _capture();
      if (!current()) return;
      if (_controller.setup != null || _controller.createOutcomeUnknown) {
        unawaited(_controller.refresh(current: current));
      }
    });
  }

  bool Function() _capture() {
    final accountEpoch = _account.generation;
    return () =>
        _active &&
        _account.isCurrent(accountEpoch) &&
        _account.isCurrent(_accountEpoch);
  }

  void _changed() {
    _syncInputs();
    if (mounted) setState(() {});
  }

  String? _signature(ServerMusicProviderSetup? setup) {
    if (setup?.interaction != ServerMusicProviderSetupInteraction.submitForm) {
      return null;
    }
    return '${setup!.id}:${setup.revision}:'
        '${setup.fields.map((field) => '${field.key}:${field.type.name}:${field.required}').join('|')}';
  }

  void _syncInputs() {
    final setup = _controller.setup;
    final setupRevision = setup == null
        ? null
        : '${setup.id}:${setup.revision}';
    if (setupRevision != _setupRevision) {
      _setupRevision = setupRevision;
      _externalOpened = false;
      _externalFailed = false;
      _formIncomplete = false;
    }
    final signature = _signature(setup);
    if (signature == _fieldRevision) return;
    _clearInputs();
    _fieldRevision = signature;
    if (signature == null || setup == null) return;
    for (final field in setup.fields) {
      if (field.type == ServerMusicProviderSetupFieldType.boolean) {
        _booleanFields[field.key] = false;
      } else {
        _textFields[field.key] = TextEditingController();
      }
    }
  }

  void _clearInputs() {
    for (final controller in _textFields.values) {
      controller.clear();
      controller.dispose();
    }
    _textFields.clear();
    _booleanFields.clear();
    _fieldRevision = null;
    _formIncomplete = false;
  }

  void _create(ServerMusicProviderDomain domain) {
    final current = _capture();
    if (current()) {
      unawaited(_controller.create(domain, current: current));
    }
  }

  void _loadCapabilities() {
    final current = _capture();
    if (current()) {
      unawaited(_controller.loadCapabilities(current: current));
    }
  }

  void _refresh() {
    final current = _capture();
    if (current()) unawaited(_controller.refresh(current: current));
  }

  void _cancel() {
    final current = _capture();
    if (current()) unawaited(_controller.cancel(current: current));
  }

  void _retry() {
    final current = _capture();
    if (current()) unawaited(_controller.retry(current: current));
  }

  void _resume() {
    final current = _capture();
    if (current()) unawaited(_controller.resume(current: current));
  }

  Future<void> _launch() async {
    final setup = _controller.setup;
    final uri = setup?.externalUrl;
    final current = _capture();
    if (uri == null || !current()) return;
    bool opened;
    try {
      opened = await _openExternal(uri);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    setState(() {
      _externalOpened = opened;
      _externalFailed = !opened;
    });
  }

  void _submit() {
    final setup = _controller.setup;
    if (setup == null ||
        setup.interaction != ServerMusicProviderSetupInteraction.submitForm) {
      return;
    }
    final values = <String, Object>{};
    var incomplete = false;
    for (final field in setup.fields) {
      if (field.type == ServerMusicProviderSetupFieldType.boolean) {
        values[field.key] = _booleanFields[field.key] ?? false;
        continue;
      }
      final value = _textFields[field.key]?.text ?? '';
      if (field.required && value.isEmpty) incomplete = true;
      if (value.isNotEmpty) values[field.key] = value;
    }
    if (incomplete) {
      setState(() => _formIncomplete = true);
      return;
    }
    _formIncomplete = false;
    late final ServerMusicProviderSetupSubmission submission;
    try {
      submission = ServerMusicProviderSetupSubmission(values);
    } catch (_) {
      setState(() => _formIncomplete = true);
      return;
    }
    final current = _capture();
    if (current()) {
      unawaited(_controller.submit(submission, current: current));
    }
  }

  String _interaction(
    AppLocalizations l,
    ServerMusicProviderInteraction interaction,
  ) => switch (interaction) {
    ServerMusicProviderInteraction.oauthAndPlaybackApproval =>
      l.serverMusicProviderSetupSpotifyFlow,
    ServerMusicProviderInteraction.musicKitOrSecureManualToken =>
      l.serverMusicProviderSetupAppleFlow,
    ServerMusicProviderInteraction.secureCookieAndPoTokenService =>
      l.serverMusicProviderSetupYoutubeFlow,
  };

  String _state(AppLocalizations l, ServerMusicProviderSetupState state) =>
      switch (state) {
        ServerMusicProviderSetupState.queued =>
          l.serverMusicProviderSetupQueued,
        ServerMusicProviderSetupState.actionRequired =>
          l.serverMusicProviderSetupActionRequired,
        ServerMusicProviderSetupState.needsAttention =>
          l.serverMusicProviderSetupNeedsAttention,
        ServerMusicProviderSetupState.ready => l.serverMusicProviderSetupReady,
        ServerMusicProviderSetupState.cancelled =>
          l.serverMusicProviderSetupCancelled,
      };

  String _providerName(ServerMusicProviderDomain domain) => switch (domain) {
    ServerMusicProviderDomain.spotify => 'Spotify',
    ServerMusicProviderDomain.appleMusic => 'Apple Music',
    ServerMusicProviderDomain.youtubeMusic => 'YouTube Music',
  };

  String _fieldLabel(AppLocalizations l, ServerMusicProviderSetupField field) {
    final words = field.key.split('_').where((word) => word.isNotEmpty);
    final label = words
        .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
    return '$label · '
        '${field.required ? l.serverMusicProviderSetupRequired : l.serverMusicProviderSetupOptional}';
  }

  Widget _button(String keyName, String label, VoidCallback? action) =>
      CupertinoButton.filled(
        key: ValueKey('music-provider-setup-$keyName'),
        minimumSize: const Size(48, 48),
        onPressed: action,
        child: Text(label),
      );

  Widget _capabilities(AppLocalizations l) {
    final providers = _controller.capabilities?.providers ?? const [];
    return SettingsSection(
      header: Text(l.serverMusicProviderSetupCapabilities),
      children: [
        if (providers.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: _button(
              'load-capabilities',
              l.serverMusicProviderSetupRefresh,
              _active && !_controller.busy ? _loadCapabilities : null,
            ),
          ),
        for (final provider in providers)
          Padding(
            key: ValueKey('music-provider-capability-${provider.domain.wire}'),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(provider.name, style: AppText.headline),
                ),
                const SizedBox(height: 6),
                Text(
                  provider.stage == ServerMusicProviderStage.stable
                      ? l.serverMusicProviderSetupStable
                      : l.serverMusicProviderSetupBeta,
                ),
                Text(_interaction(l, provider.interaction)),
                Text(l.serverMusicProviderSetupMultiAccount),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: _button(
                    'start-${provider.domain.wire}',
                    l.serverMusicProviderSetupStart,
                    _active && _controller.canCreate
                        ? () => _create(provider.domain)
                        : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _field(AppLocalizations l, ServerMusicProviderSetupField field) {
    final label = _fieldLabel(l, field);
    if (field.type == ServerMusicProviderSetupFieldType.boolean) {
      return Semantics(
        label: label,
        toggled: _booleanFields[field.key] ?? false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(child: Text(label)),
              CupertinoSwitch(
                key: ValueKey('music-provider-field-${field.key}'),
                value: _booleanFields[field.key] ?? false,
                onChanged: _active && !_controller.busy
                    ? (value) =>
                          setState(() => _booleanFields[field.key] = value)
                    : null,
              ),
            ],
          ),
        ),
      );
    }
    final secure = field.type == ServerMusicProviderSetupFieldType.secureString;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Semantics(
        label: label,
        textField: true,
        child: CupertinoTextField(
          key: ValueKey('music-provider-field-${field.key}'),
          controller: _textFields[field.key],
          enabled: _active && !_controller.busy,
          placeholder: label,
          maxLength: 8192,
          obscureText: secure,
          autocorrect: false,
          enableSuggestions: !secure,
          autofillHints: const <String>[],
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.next,
          padding: const EdgeInsets.all(14),
          onChanged: (_) {
            if (_formIncomplete) setState(() => _formIncomplete = false);
          },
        ),
      ),
    );
  }

  List<Widget> _setupActions(
    AppLocalizations l,
    ServerMusicProviderSetup setup,
  ) {
    final readable = _active && !_controller.busy;
    final enabled = readable && !_controller.needsRefresh;
    final recovery =
        _controller.needsRefresh &&
            setup.state != ServerMusicProviderSetupState.queued
        ? <Widget>[
            _button(
              'refresh-recovery',
              l.serverMusicProviderSetupRefresh,
              readable ? _refresh : null,
            ),
            const SizedBox(height: 8),
          ]
        : const <Widget>[];
    return [
      ...recovery,
      ...switch (setup.state) {
        ServerMusicProviderSetupState.queued => [
          Text(l.serverMusicProviderSetupQueuedHint),
          const SizedBox(height: 12),
          _button(
            'refresh',
            l.serverMusicProviderSetupRefresh,
            readable ? _refresh : null,
          ),
          const SizedBox(height: 8),
          _button(
            'cancel',
            l.serverMusicProviderSetupCancel,
            enabled ? _cancel : null,
          ),
        ],
        ServerMusicProviderSetupState.actionRequired => [
          if (setup.interaction ==
              ServerMusicProviderSetupInteraction.openExternal) ...[
            Text(l.serverMusicProviderSetupExternalHint),
            const SizedBox(height: 12),
            _button(
              'open-external',
              l.serverMusicProviderSetupOpenExternal,
              enabled ? () => unawaited(_launch()) : null,
            ),
            if (_externalFailed) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(l.serverMusicProviderSetupExternalFailed),
              ),
            ],
            const SizedBox(height: 8),
            _button(
              'resume',
              l.serverMusicProviderSetupResume,
              enabled && _externalOpened ? _resume : null,
            ),
          ] else ...[
            Text(l.serverMusicProviderSetupFormHint),
            const SizedBox(height: 8),
            for (final field in setup.fields) _field(l, field),
            if (_formIncomplete)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(l.serverMusicProviderSetupIncomplete),
                ),
              ),
            _button(
              'submit',
              l.serverMusicProviderSetupSubmit,
              enabled ? _submit : null,
            ),
          ],
          const SizedBox(height: 8),
          _button(
            'cancel',
            l.serverMusicProviderSetupCancel,
            enabled ? _cancel : null,
          ),
        ],
        ServerMusicProviderSetupState.needsAttention => [
          Text(l.serverMusicProviderSetupAttentionHint),
          const SizedBox(height: 12),
          _button(
            'retry',
            l.serverMusicProviderSetupRetry,
            enabled ? _retry : null,
          ),
          const SizedBox(height: 8),
          _button(
            'cancel',
            l.serverMusicProviderSetupCancel,
            enabled ? _cancel : null,
          ),
        ],
        ServerMusicProviderSetupState.ready => [
          Text(l.serverMusicProviderSetupReadyHint),
        ],
        ServerMusicProviderSetupState.cancelled => [
          Text(l.serverMusicProviderSetupCancelledHint),
        ],
      },
    ];
  }

  Widget _progress(AppLocalizations l, ServerMusicProviderSetup setup) =>
      SettingsSection(
        header: Text(l.serverMusicProviderSetupProgress),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  liveRegion: true,
                  child: Text(_state(l, setup.state), style: AppText.headline),
                ),
                const SizedBox(height: 4),
                Text('${_providerName(setup.domain)} · r${setup.revision}'),
                const SizedBox(height: 12),
                ..._setupActions(l, setup),
              ],
            ),
          ),
        ],
      );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _account.removeListener(_accountChanged);
    _controller.removeListener(_changed);
    _clearInputs();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final setup = _controller.setup;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l.serverMusicProviderSetupTitle),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    l.serverMusicProviderSetupIntro,
                    style: AppText.body,
                  ),
                ),
              ),
            ),
            if (_controller.busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CupertinoActivityIndicator()),
              ),
            if (_controller.failure != null)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l.serverMusicProviderSetupFailure),
                ),
              ),
            if (_controller.createOutcomeUnknown)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(l.serverMusicProviderSetupUnknownCreate),
                    ),
                    const SizedBox(height: 8),
                    _button(
                      'refresh-create',
                      l.serverMusicProviderSetupRefresh,
                      _active && !_controller.busy ? _refresh : null,
                    ),
                  ],
                ),
              ),
            if (_controller.needsRefresh)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l.serverMusicProviderSetupNeedsRefresh),
                ),
              ),
            if (_controller.reconciled)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l.serverMusicProviderSetupReconciled),
                ),
              ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  children: [
                    if (setup != null) _progress(l, setup),
                    _capabilities(l),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
