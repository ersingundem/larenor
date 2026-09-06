import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../server/admin/domain/server_admin_models.dart';
import '../data/home_resources_api.dart';
import '../data/home_resource_grants_controller.dart';
import '../domain/home_resource_grants.dart';
import '../domain/home_resource_models.dart';

/// A child route of the verified Settings gate, with its own session-owned read.
class HomeResourceGrantsScreen extends ConsumerStatefulWidget {
  const HomeResourceGrantsScreen({
    super.key,
    required this.target,
    required this.gateCurrent,
  });
  final HomeResourceRecord target;
  final bool Function() gateCurrent;
  @override
  ConsumerState<HomeResourceGrantsScreen> createState() =>
      _HomeResourceGrantsScreenState();
}

class _HomeResourceGrantsScreenState
    extends ConsumerState<HomeResourceGrantsScreen>
    with WidgetsBindingObserver {
  late final HomeResourceGrantsController _controller;
  AdminUser? _selected;
  HomeResourcePermission _permission = HomeResourcePermission.readOnly;
  bool _saving = false,
      _confirming = false,
      _foreground = true,
      _focused = true,
      _scheduled = false;
  int _generation = 0, _selectionEpoch = 0;
  int? _viewId;
  AppInteractionController? _interaction;
  int _interactionEpoch = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _controller = HomeResourceGrantsController(
      ref.read(homeSessionControllerProvider)!,
      widget.target,
      ref.read(homeResourcesApiFactoryProvider),
      ref.read(homeResourcesClockProvider),
      _current,
    )..addListener(_changed);
  }

  bool _windowAvailable() {
    final value = ref.read(windowPolicySnapshotProvider);
    if (value.isLoading || value.hasError || !value.hasValue) return false;
    final window = value.requireValue;
    return !window.supported ||
        window.isResumed && window.hasWindowFocus && !window.isPictureInPicture;
  }

  bool _current() =>
      mounted &&
      identical(ref.read(homeSessionControllerProvider), _controller.home) &&
      widget.gateCurrent() &&
      _foreground &&
      _focused &&
      _windowAvailable() &&
      (_interaction?.active ?? true) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true;

  void _wipe() {
    _generation++;
    _selected = null;
    _permission = HomeResourcePermission.readOnly;
    _confirming = false;
    _saving = false;
  }

  void _changed() {
    if (!mounted) return;
    if (_selected != null &&
        (!_controller.fresh ||
            !_current() ||
            !_saving && _selectionEpoch != _controller.epoch)) {
      _wipe();
    }
    setState(() {});
  }

  void _retireIfHidden() {
    if (!mounted) return;
    if (!_current()) _wipe();
    _controller.setVisible(_current());
  }

  void _interactionChanged() {
    if (!mounted) return;
    if (_interactionEpoch != _interaction?.epoch) {
      _interactionEpoch = _interaction?.epoch ?? 0;
      _wipe();
    }
    _retireIfHidden();
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppInteractionScope.maybeOf(context);
    if (!identical(next, _interaction)) {
      if (_interaction != null) _wipe();
      _interaction?.removeListener(_interactionChanged);
      _interaction = next;
      _interactionEpoch = next?.epoch ?? 0;
      next?.addListener(_interactionChanged);
    }
    final view = View.of(context).viewId;
    if (_viewId != null && _viewId != view) _wipe();
    _viewId = view;
    TickerMode.valuesOf(context);
    ModalRoute.of(context);
    if (!_current()) _wipe();
    _syncLater();
  }

  void _syncLater() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _retireIfHidden();
    });
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (!mounted || event.viewId != _viewId) return;
    _focused = event.state == ViewFocusState.focused;
    _retireIfHidden();
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    _foreground = state == AppLifecycleState.resumed;
    _retireIfHidden();
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_interactionChanged);
    _controller.removeListener(_changed);
    _controller.dispose();
    _wipe();
    super.dispose();
  }

  VoidCallback _callback(VoidCallback action) {
    final generation = _generation,
        epoch = _controller.epoch,
        interactionEpoch = _interaction?.epoch;
    return () {
      if (_current() &&
          generation == _generation &&
          epoch == _controller.epoch &&
          interactionEpoch == _interaction?.epoch) {
        action();
      }
    };
  }

  void _choose(AdminUser user) {
    if (!_controller.canChange || _selected != null) return;
    setState(() {
      _wipe();
      _selected = user;
      _selectionEpoch = _controller.epoch;
      final current = _controller.snapshot!.permissionFor(user.id);
      _permission = current == HomeResourcePermission.none
          ? HomeResourcePermission.readOnly
          : current;
    });
  }

  Future<void> _save() async {
    if (_selected == null || _saving || !_controller.canChange || !_current()) {
      return;
    }
    if (_permission == HomeResourcePermission.none && !_confirming) {
      setState(() {
        // The proposal and its confirmation are distinct callback generations.
        // A retained Save/permission callback cannot confirm or alter it.
        _generation++;
        _confirming = true;
      });
      return;
    }
    final selected = _selected!,
        permission = _permission,
        generation = _generation,
        interactionEpoch = _interaction?.epoch;
    bool current() =>
        _current() &&
        generation == _generation &&
        interactionEpoch == _interaction?.epoch &&
        _controller.fresh;
    setState(() => _saving = true);
    await _controller.setPermission(selected, permission, isCurrent: current);
    if (mounted && generation == _generation) setState(_wipe);
  }

  Widget _button(
    String key,
    String label,
    VoidCallback? action, {
    bool selected = false,
    bool destructive = false,
  }) => Semantics(
    selected: selected,
    child: CupertinoButton(
      key: ValueKey(key),
      minimumSize: const Size(48, 48),
      focusColor: CupertinoTheme.of(context).primaryColor,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      onPressed: action == null ? null : _callback(action),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) ...[
            const Icon(CupertinoIcons.checkmark, size: 20),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: destructive
                  ? TextStyle(
                      color: CupertinoColors.systemRed.resolveFrom(context),
                    )
                  : null,
            ),
          ),
        ],
      ),
    ),
  );
  String _permissionLabel(
    AppLocalizations l10n,
    HomeResourcePermission permission,
  ) => switch (permission) {
    HomeResourcePermission.none => l10n.resourceGrantsNone,
    HomeResourcePermission.readOnly => l10n.resourceGrantsReadOnly,
    HomeResourcePermission.readWrite => l10n.resourceGrantsReadWrite,
  };
  @override
  Widget build(BuildContext context) {
    ref.watch(homeSessionControllerProvider);
    ref.listen(windowPolicySnapshotProvider, (_, _) {
      _retireIfHidden();
      if (mounted) setState(() {});
    });
    _syncLater();
    final l10n = AppLocalizations.of(context), outcome = _controller.outcome;
    final message = switch (outcome) {
      HomeResourceGrantOutcome.saved => l10n.resourceGrantsSaved,
      HomeResourceGrantOutcome.revoked => l10n.resourceGrantsRevoked,
      HomeResourceGrantOutcome.conflict => l10n.resourceGrantsConflict,
      HomeResourceGrantOutcome.uncertain => l10n.resourceGrantsUncertain,
      HomeResourceGrantOutcome.failed => l10n.resourceGrantsFailed,
      null => null,
    };
    return AppPageScaffold(
      key: const ValueKey('home-resource-grants-screen'),
      child: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                _button(
                  'resource-grants-back',
                  l10n.commonBack,
                  () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      l10n.resourceGrantsTitle,
                      style: CupertinoTheme.of(context)
                          .textTheme
                          .navTitleTextStyle,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: !_current() || !_controller.fresh
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            children: [
                              Text(l10n.homeResourceAdminRequired),
                              if (_controller.canRefresh)
                                _button(
                                  'resource-grants-refresh',
                                  l10n.commonRefresh,
                                  () => unawaited(_controller.refresh()),
                                ),
                            ],
                          ),
                        )
                      : CustomScrollView(
                          slivers: [
                            SliverPadding(
                              padding: const EdgeInsets.all(20),
                              sliver: SliverToBoxAdapter(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Semantics(
                                      header: true,
                                      child: Text(
                                        widget.target.label,
                                        style: CupertinoTheme.of(context)
                                            .textTheme
                                            .navTitleTextStyle,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(l10n.resourceGrantsDescription),
                                    const SizedBox(height: 12),
                                    Text(l10n.resourceGrantsInherited),
                                    if (message != null)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                        child: Semantics(
                                          liveRegion: true,
                                          child: Text(
                                            message,
                                            key: ValueKey(
                                              'resource-grants-${outcome!.name}',
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (_controller.busy)
                                      Semantics(
                                        liveRegion: true,
                                        child: Text(
                                          _saving
                                              ? l10n.homeResourceAdminSaving
                                              : l10n.homeResourcesLoading,
                                        ),
                                      ),
                                    if (_selected == null) ...[
                                      if (_controller.failure != null &&
                                          message == null)
                                        Text(l10n.resourceGrantsReadFailed),
                                      _button(
                                        'resource-grants-refresh',
                                        l10n.commonRefresh,
                                        _controller.canRefresh
                                            ? () => unawaited(
                                                _controller.refresh(),
                                              )
                                            : null,
                                      ),
                                      if (_controller.snapshot != null &&
                                          _controller.users.isEmpty)
                                        Text(l10n.resourceGrantsNoUsers),
                                    ] else ...[
                                      Semantics(
                                        header: true,
                                        child: Text(_selected!.username),
                                      ),
                                      if (_confirming) ...[
                                        Text(
                                          l10n.resourceGrantsConfirmRevoke,
                                          key: const ValueKey(
                                            'resource-grants-revoke-confirmation',
                                          ),
                                        ),
                                        Text(l10n.resourceGrantsRevokeHint),
                                        _button(
                                          'resource-grants-confirm-revoke',
                                          l10n.resourceGrantsRevoke,
                                          _saving
                                              ? null
                                              : () => unawaited(_save()),
                                          destructive: true,
                                        ),
                                      ] else ...[
                                        for (final permission
                                            in HomeResourcePermission.values)
                                          _button(
                                            'resource-grants-${permission.name}',
                                            _permissionLabel(l10n, permission),
                                            _saving
                                                ? null
                                                : () => setState(
                                                    () => _permission =
                                                        permission,
                                                  ),
                                            selected: _permission == permission,
                                          ),
                                        _button(
                                          'resource-grants-save',
                                          l10n.commonSave,
                                          _saving
                                              ? null
                                              : () => unawaited(_save()),
                                        ),
                                      ],
                                      _button(
                                        'resource-grants-cancel',
                                        l10n.commonCancel,
                                        _saving ? null : () => setState(_wipe),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            if (_selected == null)
                              SliverList.builder(
                                itemCount: _controller.users.length,
                                itemBuilder: (context, index) {
                                  final user = _controller.users[index],
                                      permission = _controller.snapshot!
                                          .permissionFor(user.id);
                                  final tags = [
                                    if (user.disabled) l10n.serverAdminDisabled,
                                    if (user.role.name == 'admin')
                                      l10n.serverAdministrator,
                                  ];
                                  return Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      20,
                                      0,
                                      20,
                                      16,
                                    ),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: CupertinoColors
                                            .secondarySystemGroupedBackground
                                            .resolveFrom(context),
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            _button(
                                              'resource-grants-user-${user.id}',
                                              user.username,
                                              _controller.canChange
                                                  ? () => _choose(user)
                                                  : null,
                                            ),
                                            Text(
                                              _permissionLabel(
                                                l10n,
                                                permission,
                                              ),
                                            ),
                                            if (tags.isNotEmpty)
                                              Text(tags.join(' · ')),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
