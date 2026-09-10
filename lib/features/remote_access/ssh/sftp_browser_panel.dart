import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/remote_profiles.dart';
import 'sftp_controller.dart';
import 'sftp_engine.dart';
import 'sftp_file_access.dart';
import 'sftp_models.dart';
import 'ssh_terminal_panel.dart' show sshSecurityStoreProvider;

final sftpEngineFactoryProvider = Provider<SftpEngine Function()>(
  (_) => DartSftpEngine.new,
);
final sftpFileAccessProvider = Provider<SftpFileAccess>(
  (_) => SftpFileAccess(),
);

class SftpBrowserPanel extends ConsumerStatefulWidget {
  const SftpBrowserPanel({
    super.key,
    required this.profile,
    required this.isCurrent,
    required this.onBack,
  });

  final RemoteProfile profile;
  final bool Function() isCurrent;
  final VoidCallback onBack;

  @override
  ConsumerState<SftpBrowserPanel> createState() => _SftpBrowserPanelState();
}

class _SftpBrowserPanelState extends ConsumerState<SftpBrowserPanel>
    with WidgetsBindingObserver {
  ProviderContainer? _container;
  AppInteractionController? _interaction;
  SftpController? _controller;
  Object? _storeIdentity, _engineIdentity, _fileIdentity;
  bool _retired = false, _resumed = true, _focused = true;

  bool _current() {
    try {
      if (_retired ||
          !mounted ||
          !_resumed ||
          !_focused ||
          !widget.isCurrent() ||
          _interaction?.active == false ||
          ModalRoute.of(context)?.isCurrent != true ||
          !TickerMode.valuesOf(context).enabled ||
          !identical(
            _container,
            ProviderScope.containerOf(context, listen: false),
          )) {
        return false;
      }
      if (_controller != null &&
          (!identical(_storeIdentity, ref.read(sshSecurityStoreProvider)) ||
              !identical(
                _engineIdentity,
                ref.read(sftpEngineFactoryProvider),
              ) ||
              !identical(_fileIdentity, ref.read(sftpFileAccessProvider)))) {
        return false;
      }
      final state = ref.read(windowPolicySnapshotProvider);
      if (state.isLoading || state.hasError || !state.hasValue) return false;
      final window = state.value!;
      return !window.supported ||
          (window.isResumed &&
              window.hasWindowFocus &&
              !window.isPictureInPicture);
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ProviderScope.containerOf(context, listen: false);
    if (_container != null && !identical(_container, next)) _retire();
    _container = next;
    final interaction = AppInteractionScope.maybeOf(context);
    if (!identical(interaction, _interaction)) {
      _interaction?.removeListener(_ownerChanged);
      _interaction = interaction;
      interaction?.addListener(_ownerChanged);
    }
    if (!TickerMode.valuesOf(context).enabled) _retire();
  }

  @override
  void didUpdateWidget(covariant SftpBrowserPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.toJson().toString() !=
        widget.profile.toJson().toString()) {
      _retire();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) _retire();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (mounted && event.viewId == View.of(context).viewId) {
      _focused = event.state == ViewFocusState.focused;
      if (!_focused) _retire();
    }
  }

  void _ownerChanged() {
    if (!_current()) _retire();
  }

  void _changed() {
    if (!mounted) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _controller?.retire();
    _changed();
  }

  @override
  void dispose() {
    _retired = true;
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_ownerChanged);
    _controller?.removeListener(_changed);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localization = AppLocalizations.of(context);
    final store = ref.watch(sshSecurityStoreProvider);
    final engineFactory = ref.watch(sftpEngineFactoryProvider);
    final fileAccess = ref.watch(sftpFileAccessProvider);
    if (_controller == null) {
      _storeIdentity = store;
      _engineIdentity = engineFactory;
      _fileIdentity = fileAccess;
      _controller = SftpController(
        profile: widget.profile,
        store: store,
        engineFactory: engineFactory,
        fileAccess: fileAccess,
        isCurrent: _current,
      )..addListener(_changed);
    }
    if (!identical(store, _storeIdentity) ||
        !identical(engineFactory, _engineIdentity) ||
        !identical(fileAccess, _fileIdentity)) {
      _retire();
    }
    ref.listen(windowPolicySnapshotProvider, (_, next) {
      if (!_current()) _retire();
    });
    ref.watch(windowPolicySnapshotProvider);
    final controller = _controller!;
    final active = _current();

    Widget action(
      String key,
      String title,
      VoidCallback callback, {
      String? subtitle,
      bool enabled = true,
    }) => SettingsActionTile(
      key: ValueKey(key),
      title: Text(title),
      additionalInfo: subtitle == null ? null : Text(subtitle),
      onTap: active && enabled
          ? () {
              if (_current()) callback();
            }
          : null,
    );

    String errorText() => switch (controller.error) {
      'host_changed' => localization.sshHostChanged,
      'credential_missing' => localization.sshCredentialMissing,
      'profile_changed' => localization.sshProfileChanged,
      'timed_out' => localization.sshTimeout,
      'invalid_path' || 'invalid_name' => localization.sftpInvalidPath,
      'file_too_large' => localization.sftpFileTooLarge,
      'already_exists' => localization.sftpAlreadyExists,
      'file_access_failed' => localization.sftpFileAccessFailed,
      _ => localization.sftpFailed,
    };

    String phaseText() => switch (controller.phase) {
      SftpPhase.idle => localization.sftpReady,
      SftpPhase.connecting => localization.sshConnecting,
      SftpPhase.hostKey => localization.sshVerifyHost,
      SftpPhase.ready => localization.sftpConnected,
      SftpPhase.listing => localization.sftpListing,
      SftpPhase.downloading => localization.sftpDownloading,
      SftpPhase.uploading => localization.sftpUploading,
      SftpPhase.closed => localization.sshClosed,
      SftpPhase.failed => localization.sftpFailed,
    };

    final busy =
        controller.phase == SftpPhase.connecting ||
        controller.phase == SftpPhase.hostKey ||
        controller.phase == SftpPhase.listing ||
        controller.phase == SftpPhase.downloading ||
        controller.phase == SftpPhase.uploading;
    final ready = controller.phase == SftpPhase.ready;
    final pin = controller.pendingPin;

    return AppPageScaffold(
      child: CustomScrollView(
        key: const ValueKey('sftp-scroll'),
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(localization.sftpTitle),
          ),
          SliverSafeArea(
            top: false,
            sliver: SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Semantics(
                              header: true,
                              child: Text(widget.profile.name),
                            ),
                            Text(
                              '${widget.profile.username}@${widget.profile.address}',
                            ),
                            const SizedBox(height: 12),
                            Text(localization.sftpHint),
                            const SizedBox(height: 12),
                            Text(
                              active
                                  ? phaseText()
                                  : localization.remoteAccessLocked,
                              key: const ValueKey('sftp-status'),
                            ),
                            if (controller.error != null)
                              Text(
                                errorText(),
                                key: const ValueKey('sftp-error'),
                              ),
                            if (controller.notice case final notice?)
                              Text(
                                notice == 'uploaded'
                                    ? localization.sftpUploadComplete
                                    : notice == 'downloaded'
                                    ? localization.sftpDownloadComplete
                                    : localization.sftpDownloadCancelled,
                                key: const ValueKey('sftp-notice'),
                              ),
                            if (busy && controller.progress > 0)
                              Text(
                                localization.sftpTransferred(
                                  controller.progress,
                                ),
                                key: const ValueKey('sftp-progress'),
                              ),
                          ],
                        ),
                      ),
                      if (active && pin != null)
                        SettingsSection(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(localization.sshTrustHint),
                                  Text(pin.type),
                                  SelectableText(pin.fingerprint),
                                ],
                              ),
                            ),
                            action(
                              'sftp-trust',
                              localization.sshTrust,
                              () => unawaited(controller.trustHost()),
                            ),
                            action(
                              'sftp-cancel',
                              localization.commonCancel,
                              controller.cancel,
                            ),
                          ],
                        )
                      else if (active && ready) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                          child: SelectableText(
                            controller.path,
                            key: const ValueKey('sftp-path'),
                          ),
                        ),
                        if (controller.truncated)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Text(localization.sftpListingTruncated),
                          ),
                        SettingsSection(
                          children: [
                            if (controller.path != '/')
                              action(
                                'sftp-parent',
                                localization.sftpParent,
                                () => unawaited(
                                  controller.openDirectory(
                                    sftpParentPath(controller.path),
                                  ),
                                ),
                              ),
                            action(
                              'sftp-refresh',
                              localization.commonRefresh,
                              () => unawaited(
                                controller.openDirectory(controller.path),
                              ),
                            ),
                            action(
                              'sftp-upload',
                              localization.sftpUpload,
                              () => unawaited(controller.pickAndUpload()),
                            ),
                          ],
                        ),
                        if (controller.entries.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(localization.sftpEmpty),
                          )
                        else
                          SettingsSection(
                            children: [
                              for (final entry in controller.entries)
                                action(
                                  entry.isDirectory
                                      ? 'sftp-entry-${entry.name}'
                                      : 'sftp-download-${entry.name}',
                                  entry.isDirectory
                                      ? '📁 ${entry.name}'
                                      : localization.sftpDownload(entry.name),
                                  () => unawaited(
                                    entry.isDirectory
                                        ? controller.openDirectory(entry.path)
                                        : controller.download(entry),
                                  ),
                                  subtitle: entry.size == null
                                      ? null
                                      : localization.sftpFileSize(entry.size!),
                                ),
                            ],
                          ),
                        SettingsSection(
                          children: [
                            action(
                              'sftp-disconnect',
                              localization.sshDisconnect,
                              controller.cancel,
                            ),
                          ],
                        ),
                      ] else if (active && busy)
                        SettingsSection(
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(20),
                              child: CupertinoActivityIndicator(),
                            ),
                            action(
                              'sftp-cancel',
                              localization.commonCancel,
                              controller.cancel,
                            ),
                          ],
                        )
                      else if (active)
                        SettingsSection(
                          children: [
                            action(
                              'sftp-connect',
                              localization.sftpConnect,
                              () => unawaited(controller.connect()),
                            ),
                          ],
                        ),
                      if (active)
                        SettingsSection(
                          children: [
                            action('sftp-back', localization.commonBack, () {
                              controller.cancel();
                              widget.onBack();
                            }),
                          ],
                        ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
