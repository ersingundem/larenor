import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/theme/typography.dart';
import '../../../../shared/widgets/app_page_scaffold.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../media/hub/presentation/media_session_state.dart';
import '../../../settings/providers/settings_providers.dart';
import '../../data/server_account_controller.dart';
import '../../providers/server_providers.dart';
import '../data/server_component_updates_controller.dart';
import '../domain/server_component_update_models.dart';

final class ServerComponentUpdatesScreen extends ConsumerStatefulWidget {
  const ServerComponentUpdatesScreen({super.key});

  @override
  ConsumerState<ServerComponentUpdatesScreen> createState() =>
      _ServerComponentUpdatesScreenState();
}

final class _ServerComponentUpdatesScreenState
    extends MediaSessionState<ServerComponentUpdatesScreen> {
  late final ServerAccountController _account;
  late final ServerComponentUpdatesController _updates;
  late final int _accountEpoch;
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true;
  bool _expired = false;
  bool _loaded = false;
  bool _pinReady = false;
  bool _wasCurrent = true;

  bool get _active =>
      !_expired &&
      _visible &&
      _pinReady &&
      sessionCurrent(sessionGeneration) &&
      _account.isCurrent(_accountEpoch) &&
      _account.initialized &&
      !_account.working &&
      _account.session?.user.canAdminister == true &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountEpoch = _account.generation;
    _updates = ServerComponentUpdatesController(_account);
    _account.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (!_account.isCurrent(_accountEpoch) ||
        _account.working ||
        _account.session?.user.canAdminister != true) {
      _expire();
    }
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
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_wasCurrent && !current) _expire();
    _wasCurrent = current;
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  @override
  void clearPendingInteraction() => _expire();

  void _expire() {
    if (!mounted || _expired) return;
    _expired = true;
    sessionGeneration++;
    _updates.invalidate();
  }

  @override
  void dispose() {
    _account.removeListener(_accountChanged);
    _ticker?.removeListener(_visibilityChanged);
    _updates.dispose();
    super.dispose();
  }

  bool Function() _capture() {
    final epoch = sessionGeneration;
    return () => mounted && sessionCurrent(epoch) && _active;
  }

  Future<void> _load() async {
    if (!_active || _updates.busy) return;
    await _updates.load(current: _capture());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pin = ref.watch(pinLockProvider);
    _pinReady = !pin.isLoading && !pin.hasError;
    ref.listen(pinLockProvider, (previous, next) {
      if (next.isLoading ||
          next.hasError ||
          (previous?.hasValue == true && previous?.value != next.value)) {
        _expire();
      }
    });
    if (_active && !_loaded) {
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active) unawaited(_load());
      });
    }
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          l10n.serverComponentUpdatesTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _updates,
          builder: (context, _) {
            if (!_active) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _account.session?.user.canAdminister == true
                        ? l10n.serverOpenFromSettings
                        : l10n.serverFailurePermission,
                  ),
                ),
              );
            }
            final inventory = _updates.inventory;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: ListView(
                  key: const ValueKey('server-component-updates-list'),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(l10n.serverComponentUpdatesIntro),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: CupertinoButton(
                          key: const ValueKey(
                            'server-component-updates-refresh',
                          ),
                          onPressed: _updates.busy ? null : _load,
                          child: Text(l10n.commonRefresh),
                        ),
                      ),
                    ),
                    if (_updates.busy)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: CupertinoActivityIndicator(),
                      ),
                    if (_updates.failure != null)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _updates.failure ==
                                        'component_update_worker_unavailable' ||
                                    _updates.failure ==
                                        'component_update_unavailable'
                                ? l10n.serverComponentUpdatesWorkerUnavailable
                                : l10n.serverFailureConnection,
                          ),
                        ),
                      ),
                    if (inventory != null && inventory.installed.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(l10n.serverComponentUpdatesEmpty),
                      ),
                    if (inventory != null)
                      for (
                        var index = 0;
                        index < inventory.installed.length;
                        index++
                      )
                        _component(
                          l10n,
                          inventory.installed[index],
                          inventory.reviews[index],
                        ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _component(
    AppLocalizations l10n,
    ServerInstalledComponentUpdate installed,
    ServerComponentUpdateReview review,
  ) {
    final release = installed.release;
    final status = review.isCurrent
        ? l10n.serverComponentUpdatesCurrent
        : l10n.serverComponentUpdatesBlocked;
    return SettingsSection(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      header: Text('${_serviceName(release.serviceId)} ${release.version}'),
      footer: Text(l10n.serverComponentUpdatesApplyUnavailable),
      children: [
        _valueRow(l10n.serverComponentUpdatesCurrent, status),
        _valueRow(l10n.serverComponentUpdatesPublisher, release.publisher),
        _valueRow(l10n.serverComponentUpdatesSource, release.repository),
        _valueRow(l10n.serverComponentUpdatesPlatform, release.platform),
        _valueRow(
          release.signature.verified
              ? l10n.serverComponentUpdatesSignatureVerified
              : l10n.serverComponentUpdatesSignatureUnavailable,
          l10n.serverComponentUpdatesSignatureHint,
          warning: !release.signature.verified,
        ),
        _valueRow(
          l10n.serverComponentUpdatesPermissions,
          _permissionSummary(l10n, review),
          warning: review.addedPermissions.isNotEmpty,
        ),
        _valueRow(
          l10n.serverComponentUpdatesMigration,
          review.rollbackSnapshotRequired
              ? l10n.serverComponentUpdatesMigrationRollback
              : l10n.serverComponentUpdatesMigrationNone,
          warning: review.rollbackSnapshotRequired,
        ),
        _valueRow('Manifest SHA-256', _short(release.manifestDigest)),
        _valueRow('Image SHA-256', _short(release.imageDigest)),
      ],
    );
  }

  Widget _valueRow(String label, String value, {bool warning = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppText.headline),
            const SizedBox(height: 4),
            Text(
              value,
              style: AppText.footnote.copyWith(
                color: warning
                    ? CupertinoColors.systemOrange.resolveFrom(context)
                    : CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
      );

  String _permissionSummary(
    AppLocalizations l10n,
    ServerComponentUpdateReview review,
  ) {
    final changes = <String>[];
    if (review.addedPermissions.isNotEmpty) {
      changes.add(
        '${l10n.serverComponentUpdatesPermissionAdded}: '
        '${review.addedPermissions.join(', ')}',
      );
    }
    if (review.removedPermissions.isNotEmpty) {
      changes.add(
        '${l10n.serverComponentUpdatesPermissionRemoved}: '
        '${review.removedPermissions.join(', ')}',
      );
    }
    return changes.isEmpty
        ? l10n.serverComponentUpdatesPermissionsNone
        : changes.join('\n');
  }

  String _serviceName(String id) => switch (id) {
    'music_assistant' => 'Music Assistant',
    'qbittorrent' => 'qBittorrent',
    'jellyfin' => 'Jellyfin',
    'seerr' => 'Seerr',
    'sonarr' => 'Sonarr',
    'radarr' => 'Radarr',
    _ => id,
  };

  String _short(String value) => value.startsWith('sha256:')
      ? value.substring(7, 23)
      : value.substring(0, 16);
}
