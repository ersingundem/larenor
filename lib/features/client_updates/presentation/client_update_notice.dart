import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/typography.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../../server/data/server_account_controller.dart';
import '../../server/domain/server_models.dart';
import '../../server/providers/server_providers.dart';
import '../data/client_release_repository.dart';
import '../data/client_update_controller.dart';
import '../domain/client_update_models.dart';
import '../providers/client_update_providers.dart';
import 'client_updates_screen.dart';

// Only version numbers live in app-session memory. No release, account or token
// is persisted by the notice, including when its shell is temporarily removed.
final _dismissedVersionsProvider = Provider<Set<int>>((ref) => <int>{});

/// A foreground-only metadata check. Installation stays in the PIN-gated
/// updater, and this widget never activates a native update session.
class ClientUpdateNotice extends ConsumerStatefulWidget {
  const ClientUpdateNotice({
    super.key,
    required this.location,
    required this.onOpen,
  });

  final String location;
  final VoidCallback onOpen;

  @override
  ConsumerState<ClientUpdateNotice> createState() => _ClientUpdateNoticeState();
}

class _ClientUpdateNoticeState extends MediaSessionState<ClientUpdateNotice> {
  static const _interval = Duration(minutes: 15);
  late final ServerAccountController _account;
  late int _accountGeneration;
  ServerSession? _accountSession;
  ClientReleaseRepository? _repository;
  ClientRelease? _available;
  ValueListenable<TickerModeData>? _ticker;
  Timer? _timer;
  int _operation = 0;
  int? _resolvingGeneration;
  bool _visible = true;
  bool _wasActive = false;
  bool _checking = false;
  bool _needsCheck = true;
  bool _scheduled = false;
  bool _disposed = false;

  bool get _active =>
      !_disposed &&
      sessionCurrent(sessionGeneration) &&
      _visible &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    _account = ref.read(serverAccountControllerProvider);
    _accountGeneration = _account.generation;
    _accountSession = _account.session;
    _account.addListener(_accountChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = TickerMode.getValuesNotifier(context);
    if (!identical(next, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = next;
      _visible = next.value.enabled;
      next.addListener(_visibilityChanged);
    }
    ModalRoute.isCurrentOf(context);
    if (!_active) clearPendingInteraction();
    _schedule();
  }

  @override
  void didUpdateWidget(ClientUpdateNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) clearPendingInteraction();
    _schedule();
  }

  void _visibilityChanged() {
    if (!mounted || _disposed) return;
    _visible = _ticker?.value.enabled ?? true;
    if (!_active) clearPendingInteraction();
    setState(() {});
    _schedule();
  }

  void _accountChanged() {
    if (!mounted || _disposed) return;
    final changed =
        _accountGeneration != _account.generation ||
        !identical(_accountSession, _account.session);
    _accountGeneration = _account.generation;
    _accountSession = _account.session;
    // initialize/ensureSession emit synchronously and can rotate the session.
    // Let our own await bind its result once; never recursively initialize.
    if (_resolvingGeneration != _account.generation &&
        (changed || _account.working)) {
      clearPendingInteraction();
    }
    setState(() {});
    _schedule();
  }

  @override
  void clearPendingInteraction() {
    _operation++;
    _timer?.cancel();
    _timer = null;
    _repository?.close();
    _repository = null;
    _available = null;
    _wasActive = false;
    _needsCheck = true;
    // Only our metadata transport is owned here. A shared account refresh or
    // another settings page's sign-in/password operation must not be cancelled.
  }

  @override
  void resumeMediaSession() => _schedule();

  void _schedule() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || _disposed) return;
      if (!_active) {
        clearPendingInteraction();
        return;
      }
      if (!_wasActive) {
        _wasActive = true;
        _needsCheck = true;
      }
      if (_checking) return;
      if (_needsCheck && !_account.working) {
        _needsCheck = false;
        unawaited(_check());
      } else {
        _timer ??= Timer(_interval, () {
          _timer = null;
          if (!mounted || !_active) return;
          _needsCheck = true;
          _schedule();
          // A timer may fire with no other frame scheduled.
          setState(() {});
        });
      }
    });
  }

  bool _current(int operation, int epoch) =>
      mounted && _active && operation == _operation && sessionCurrent(epoch);

  Future<void> _check() async {
    if (!_active || _checking || _account.working) return;
    _checking = true;
    _timer?.cancel();
    _timer = null;
    final operation = ++_operation;
    final epoch = sessionGeneration;
    try {
      final installed = await ref.read(clientUpdateApiProvider).snapshot();
      if (!_current(operation, epoch)) return;
      if (!installed.supported || !installed.resumed || !installed.focused) {
        setState(() => _available = null);
        return;
      }
      if (!_account.initialized && !_account.working) {
        _resolvingGeneration = _account.generation + 1;
        final restoring = _account.initialize();
        final generation = _account.generation;
        await restoring;
        if (!_current(operation, epoch) || !_account.isCurrent(generation)) {
          return;
        }
      }
      if (_account.working ||
          _account.session == null ||
          _account.session!.user.mustChangePassword) {
        return;
      }
      _resolvingGeneration = _account.generation;
      final generation = _account.generation;
      final session = await _account.ensureSession();
      if (!_current(operation, epoch) ||
          !_account.isCurrent(generation) ||
          _account.working ||
          !identical(_account.session, session) ||
          session.user.mustChangePassword) {
        return;
      }
      _resolvingGeneration = null;
      final source = ClientUpdateSource(
        baseUrl: session.endpoint.baseUrl,
        accessToken: session.accessToken,
        isCurrent: () =>
            _current(operation, epoch) &&
            _account.isCurrent(generation) &&
            !_account.working &&
            identical(_account.session, session),
      );
      final repository = ref.read(clientReleaseFactoryProvider)(source);
      _repository = repository;
      try {
        final release = await repository.latest();
        if (!source.isCurrent()) return;
        setState(
          () => _available = release != null && installed.accepts(release)
              ? release
              : null,
        );
      } finally {
        repository.close();
        if (identical(repository, _repository)) _repository = null;
      }
    } catch (_) {
      // A quiet notice has no error UI or immediate automatic retries. In
      // particular, the account controller retires uncertain refresh tokens.
      if (_current(operation, epoch)) setState(() => _available = null);
    } finally {
      _resolvingGeneration = null;
      _checking = false;
      if (mounted && !_disposed) {
        _schedule();
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    clearPendingInteraction();
    _account.removeListener(_accountChanged);
    _ticker?.removeListener(_visibilityChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    final release = _available;
    final dismissed = ref.read(_dismissedVersionsProvider);
    if (!_active ||
        release == null ||
        dismissed.contains(release.versionCode)) {
      return const SizedBox.shrink();
    }
    final operation = _operation;
    final epoch = sessionGeneration;
    final l10n = AppLocalizations.of(context);
    bool current() =>
        _current(operation, epoch) &&
        identical(_available, release) &&
        !dismissed.contains(release.versionCode);
    return SafeArea(
      bottom: false,
      child: Padding(
        key: const ValueKey('client-update-notice'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.mist.resolveFrom(context),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: CupertinoButton(
                  key: const ValueKey('client-update-open'),
                  padding: const EdgeInsets.all(14),
                  alignment: Alignment.centerLeft,
                  onPressed: () {
                    if (!current()) return;
                    clearPendingInteraction();
                    setState(() {});
                    widget.onOpen();
                  },
                  child: Text(
                    l10n.clientUpdatesAvailable,
                    style: AppText.subhead.copyWith(
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                ),
              ),
              CupertinoButton(
                key: const ValueKey('client-update-dismiss'),
                padding: const EdgeInsets.all(12),
                onPressed: () {
                  if (current()) {
                    setState(() => dismissed.add(release.versionCode));
                  }
                },
                child: Semantics(
                  label: l10n.commonClose,
                  child: const Icon(CupertinoIcons.xmark, size: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
