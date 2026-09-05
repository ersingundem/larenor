import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../core/home_session_controller.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../dashboard/data/dashboard_repository.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../data/home_layout_access.dart';
import '../data/legacy_layout_controller.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Nested inside the existing SettingsGate, never a route around its PIN.
class LegacyLayoutScreen extends ConsumerStatefulWidget {
  const LegacyLayoutScreen({super.key});
  @override
  ConsumerState<LegacyLayoutScreen> createState() => _LegacyLayoutScreenState();
}

class _LegacyLayoutScreenState extends MediaSessionState<LegacyLayoutScreen> {
  HomeSessionController? _home;
  HomeLayoutAccess? _access;
  LegacyLayoutController? _controller;
  LegacyLayoutPreview? _preview;
  CupertinoDialogRoute<bool>? _dialog;
  Timer? _expiry;
  final _selected = <int>{};
  int _operation = 0;
  bool _busy = false, _copied = false, _started = false;
  String? _failure;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final home = ref.read(homeSessionControllerProvider);
    if (!identical(home, _home)) {
      _home?.removeListener(_authorityChanged);
      _home = home;
      home?.addListener(_authorityChanged);
    }
    if (_started && !_visible) _invalidate();
    if (!_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  bool get _visible =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent == true || _dialog?.isCurrent == true);
  bool _current(int generation, int operation) =>
      sessionCurrent(generation) &&
      _visible &&
      _operation == operation &&
      _access?.isCurrent == true;

  void _authorityChanged() {
    if (!mounted) return;
    if (_access != null && !_access!.isCurrent) _invalidate();
    setState(() {});
  }

  void _invalidate() {
    _operation++;
    _controller?.close();
    _controller = null;
    _access = null;
    _preview = null;
    _selected.clear();
    _expiry?.cancel();
    _busy = false;
    _copied = false;
    _failure = 'expired';
    final dialog = _dialog;
    _dialog = null;
    if (dialog != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (dialog.isActive) dialog.navigator?.removeRoute(dialog);
      });
    }
  }

  @override
  void clearPendingInteraction() => _invalidate();

  Future<void> _load() async {
    final generation = sessionGeneration;
    if (_busy || !sessionCurrent(generation) || !_visible || _dialog != null)
      return;
    _invalidate();
    final access = homeLayoutAccess(
      _home,
      clock: ref.read(homeLayoutClockProvider),
    );
    if (access == null) {
      setState(() {});
      return;
    }
    _access = access;
    final operation = _operation;
    final destination = ref.read(dashboardRepositoryProvider);
    if (destination.scope != access.scope) { setState(_invalidate); return; }
    final controller = LegacyLayoutController(
      destination: destination,
      isCurrent: () => _current(generation, operation),
      clock: ref.read(homeLayoutClockProvider),
    );
    _controller = controller;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final preview = await controller.preview();
      if (!_current(generation, operation)) return;
      setState(() {
        _preview = preview;
      });
      final now = ref.read(homeLayoutClockProvider)();
      final deadline = preview.createdAt.add(LegacyLayoutController.lifetime);
      final until = access.validUntil.isBefore(deadline)
          ? access.validUntil
          : deadline;
      _expiry = Timer(until.difference(now), () {
        if (mounted && _operation == operation) setState(_invalidate);
      });
    } catch (error) {
      if (_current(generation, operation))
        setState(() => _failure = _code(error));
    } finally {
      if (mounted && _operation == operation) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final generation = sessionGeneration, operation = _operation;
    final preview = _preview, controller = _controller;
    if (!_current(generation, operation) ||
        _busy ||
        _dialog != null ||
        preview == null ||
        controller == null ||
        _selected.isEmpty)
      return;
    final selected = Set<int>.of(_selected);
    final l10n = AppLocalizations.of(context);
    late final CupertinoDialogRoute<bool> route;
    route = CupertinoDialogRoute<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.homeLayoutCopySelected),
        content: Text(l10n.homeLayoutConfirm(selected.length)),
        actions: [
          CupertinoDialogAction(
            onPressed: () {
              if (identical(_dialog, route) && route.isCurrent && _current(generation, operation))
                Navigator.of(dialogContext).pop(false);
            },
            child: Text(l10n.commonCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('home-layout-confirm-copy'),
            onPressed: () {
              if (identical(_dialog, route) && route.isCurrent && _current(generation, operation))
                Navigator.of(dialogContext).pop(true);
            },
            child: Text(l10n.homeLayoutCopySelected),
          ),
        ],
      ),
    );
    _dialog = route;
    final confirmed = await Navigator.of(context).push(route);
    if (identical(_dialog, route)) _dialog = null;
    if (!_current(generation, operation) || confirmed != true) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await controller.apply(preview, selected);
      if (_current(generation, operation))
        setState(() {
          _copied = true;
          _preview = null;
          _selected.clear();
          _expiry?.cancel();
        });
    } catch (error) {
      if (_current(generation, operation))
        setState(() {
          _failure = _code(error);
          _preview = null;
          _selected.clear();
        });
    } finally {
      if (mounted && _operation == operation) setState(() => _busy = false);
    }
  }

  String _code(Object error) =>
      error is DashboardStorageException ? error.code : 'read_failed';

  @override
  void dispose() {
    _home?.removeListener(_authorityChanged);
    _expiry?.cancel();
    _controller?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the sole repository selection alive while this explicit review is open.
    ref.watch(dashboardRepositoryProvider);
    final l10n = AppLocalizations.of(context);
    final preview = _preview;
    final generation = sessionGeneration, operation = _operation;
    final current = _current(generation, operation);
    final mayLoad =
        homeLayoutAccess(_home, clock: ref.watch(homeLayoutClockProvider)) !=
            null &&
        sessionCurrent(generation) &&
        _visible &&
        !_busy;
    return AppPageScaffold(
      key: const ValueKey('home-layout-preview-screen'),
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.homeLayoutPreviewTitle),
      ),
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 20),
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(l10n.homeLayoutPreviewHint),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(l10n.homeLayoutExcluded),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: CupertinoActivityIndicator(),
                  ),
                if (_failure != null)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _failure == 'expired'
                          ? l10n.homeLayoutExpired
                          : _failure == 'room_limit'
                          ? l10n.homeLayoutRoomLimit
                          : l10n.homeLayoutStorageError,
                    ),
                  ),
                if (_copied)
                  Padding(
                    key: const ValueKey('home-layout-copy-complete'),
                    padding: const EdgeInsets.all(20),
                    child: Text(l10n.homeLayoutCopied),
                  ),
                if (preview != null) ...[
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      l10n.homeLayoutExcludedCounts(
                        preview.excludedEntityReferences,
                        preview.excludedAreaBindings,
                        preview.excludedCards,
                      ),
                    ),
                  ),
                  SettingsSection(
                    header: Text(l10n.homeLayoutCurrentRooms),
                    children: [
                      if (preview.currentRoomNames.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(l10n.homeLayoutNoRooms),
                        ),
                      for (var i = 0; i < preview.currentRoomNames.length; i++)
                        Padding(
                          key: ValueKey('home-layout-current-room-$i'),
                          padding: const EdgeInsets.all(20),
                          child: Text(preview.currentRoomNames[i]),
                        ),
                    ],
                  ),
                  SettingsSection(
                    header: Text(l10n.homeLayoutLocalRooms),
                    children: [
                      if (preview.roomNames.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(l10n.homeLayoutNoRooms),
                        ),
                      for (var i = 0; i < preview.roomNames.length; i++)
                        SettingsActionTile(
                          key: ValueKey('home-layout-room-$i'),
                          title: Text(preview.roomNames[i]),
                          leading: Icon(
                            _selected.contains(i)
                                ? CupertinoIcons.check_mark_circled_solid
                                : CupertinoIcons.circle,
                          ),
                          selected: _selected.contains(i),
                          onTap: !current || _busy
                              ? null
                              : () {
                                  if (_current(generation, operation) && !_busy)
                                    setState(() {
                                      if (!_selected.remove(i))
                                        _selected.add(i);
                                    });
                                },
                        ),
                    ],
                  ),
                  SettingsSection(
                    children: [
                      SettingsActionTile(
                        key: const ValueKey('home-layout-copy-selected'),
                        title: Text(l10n.homeLayoutCopySelected),
                        onTap: current && !_busy && _selected.isNotEmpty
                            ? () {
                                if (_current(generation, operation)) _confirm();
                              }
                            : null,
                      ),
                    ],
                  ),
                ],
                SettingsSection(
                  children: [
                    SettingsActionTile(
                      key: const ValueKey('home-layout-refresh-preview'),
                      title: Text(l10n.homeLayoutRefresh),
                      onTap: mayLoad
                          ? () {
                              if (sessionCurrent(generation) &&
                                  _operation == operation &&
                                  _visible)
                                _load();
                            }
                          : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
