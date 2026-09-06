import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../server/admin/domain/server_admin_models.dart';
import '../data/home_people_providers.dart';
import '../data/home_person_grants_controller.dart';
import '../domain/home_person_models.dart';
import 'home_people_route.dart';
import 'home_people_widgets.dart';

class HomePersonGrantsScreen extends StatelessWidget {
  const HomePersonGrantsScreen({
    super.key,
    required this.target,
    required this.gateCurrent,
  });
  final HomePersonRecord target;
  final bool Function() gateCurrent;
  @override
  Widget build(BuildContext context) => HomePeopleRoute(
    title: AppLocalizations.of(context).homePeopleGrantsTitle,
    backKey: 'home-people-grants-back',
    gateCurrent: gateCurrent,
    builder: (owner) => _GrantsContent(owner: owner, target: target),
  );
}

class _GrantsContent extends ConsumerStatefulWidget {
  const _GrantsContent({required this.owner, required this.target});
  final HomePeopleOwner owner;
  final HomePersonRecord target;
  @override
  ConsumerState<_GrantsContent> createState() => _GrantsContentState();
}

class _GrantsContentState extends ConsumerState<_GrantsContent> {
  late final _selection = (owner: widget.owner, target: widget.target);
  late final HomePersonGrantsController _controller;
  AdminUser? _selected;
  HomePersonPermission _permission = HomePersonPermission.readOnly;
  bool _saving = false, _confirming = false;
  int _generation = 0, _selectionEpoch = 0;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(homePersonGrantsControllerProvider(_selection))
      ..addListener(_changed);
  }

  bool _current() => mounted && widget.owner.isCurrent;
  void _wipe() {
    _generation++;
    _selected = null;
    _permission = HomePersonPermission.readOnly;
    _saving = false;
    _confirming = false;
  }

  void _changed() {
    if (!mounted) return;
    if (_selected != null &&
        (!_current() ||
            !_controller.fresh ||
            !_saving && _selectionEpoch != _controller.epoch)) {
      _wipe();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _wipe();
    super.dispose();
  }

  VoidCallback _callback(VoidCallback action) {
    final generation = _generation, epoch = _controller.epoch;
    return () {
      if (_current() &&
          generation == _generation &&
          epoch == _controller.epoch) {
        action();
      }
    };
  }

  Widget _button(
    String key,
    String label,
    VoidCallback? action, {
    bool? selected,
    bool destructive = false,
  }) => PeopleButton(
    key: ValueKey(key),
    label: label,
    onPressed: action == null ? null : _callback(action),
    selected: selected,
    destructive: destructive,
  );
  void _choose(AdminUser user) {
    if (!_controller.canChange || _selected != null) return;
    setState(() {
      _wipe();
      _selected = user;
      _selectionEpoch = _controller.epoch;
      final permission = _controller.snapshot!.permissionFor(user.id);
      _permission = permission == HomePersonPermission.none
          ? HomePersonPermission.readOnly
          : permission;
    });
  }

  Future<void> _save() async {
    if (_selected == null || _saving || !_current() || !_controller.canChange) {
      return;
    }
    if (_permission == HomePersonPermission.none && !_confirming) {
      setState(() {
        _generation++;
        _confirming = true;
      });
      return;
    }
    final selected = _selected!,
        permission = _permission,
        generation = _generation;
    bool current() =>
        _current() && generation == _generation && _controller.fresh;
    setState(() => _saving = true);
    await _controller.setPermission(selected, permission, isCurrent: current);
    if (mounted && generation == _generation) setState(_wipe);
  }

  String _permissionLabel(AppLocalizations l, HomePersonPermission p) =>
      switch (p) {
        HomePersonPermission.none => l.homePeopleNoAccess,
        HomePersonPermission.readOnly => l.homePeopleReadOnly,
        HomePersonPermission.readWrite => l.homePeopleReadWrite,
      };
  @override
  Widget build(BuildContext context) {
    ref.watch(homePersonGrantsControllerProvider(_selection));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.setVisible(_current());
    });
    final c = _controller,
        l = AppLocalizations.of(context),
        available = _current() && c.fresh;
    final message = switch (c.outcome) {
      HomePersonGrantOutcome.saved => l.homePeopleGrantSaved,
      HomePersonGrantOutcome.revoked => l.homePeopleGrantRevoked,
      HomePersonGrantOutcome.conflict => l.homePeopleConflict,
      HomePersonGrantOutcome.uncertain => l.homePeopleUncertain,
      HomePersonGrantOutcome.failed => l.homePeopleFailed,
      null => null,
    };
    return PeoplePage(
      key: const ValueKey('home-person-grants-screen'),
      title: l.homePeopleGrantsTitle,
      backKey: 'home-people-grants-back',
      onBack: _callback(() => Navigator.of(context).maybePop()),
      slivers: [
        peopleBlock([
          if (!available) ...[
            Text(l.homePeopleAdminRequired),
            if (c.canRefresh)
              _button(
                'home-people-grant-refresh',
                l.commonRefresh,
                () => unawaited(c.refresh()),
              ),
          ] else ...[
            Semantics(
              header: true,
              child: Text(
                widget.target.label,
                style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
              ),
            ),
            const SizedBox(height: 12),
            Text(l.homePeopleGrantsDescription),
            const SizedBox(height: 12),
            Text(l.homePeopleGrantsInherited),
            if (message != null)
              peopleMessage('home-people-grant-${c.outcome!.name}', message),
            if (c.busy)
              peopleMessage(
                'home-people-grant-loading',
                _saving ? l.homePeopleSaving : l.homePeopleLoading,
              ),
            if (_selected == null) ...[
              if (c.failure != null && message == null)
                peopleMessage(
                  'home-people-grant-error',
                  l.homePeopleGrantsError,
                ),
              _button(
                'home-people-grant-refresh',
                l.commonRefresh,
                c.canRefresh ? () => unawaited(c.refresh()) : null,
              ),
              if (c.snapshot != null && c.users.isEmpty)
                peopleMessage('home-people-no-users', l.homePeopleGrantsEmpty),
            ] else ...[
              const SizedBox(height: 12),
              Semantics(header: true, child: Text(_selected!.username)),
              if (_confirming) ...[
                Text(
                  l.homePeopleConfirmRevoke,
                  key: const ValueKey('home-people-revoke-confirmation'),
                ),
                _button(
                  'home-people-confirm-revoke',
                  l.homePeopleRevoke,
                  _saving ? null : () => unawaited(_save()),
                  destructive: true,
                ),
              ] else ...[
                for (final p in HomePersonPermission.values)
                  _button(
                    'home-people-permission-${p.name}',
                    _permissionLabel(l, p),
                    _saving
                        ? null
                        : () => setState(() {
                            _generation++;
                            _permission = p;
                          }),
                    selected: p == _permission,
                  ),
                _button(
                  'home-people-grant-save',
                  l.commonSave,
                  _saving ? null : () => unawaited(_save()),
                ),
              ],
              _button(
                'home-people-grant-cancel',
                l.commonCancel,
                _saving ? null : () => setState(_wipe),
              ),
            ],
          ],
        ]),
        if (available && _selected == null)
          SliverList.builder(
            itemCount: c.users.length,
            itemBuilder: (context, index) {
              final user = c.users[index];
              return Padding(
                key: ValueKey('home-people-user-row-${user.id}'),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: SettingsSection(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _button(
                            'home-people-user-${user.id}',
                            user.username,
                            c.canChange ? () => _choose(user) : null,
                          ),
                          Text(
                            _permissionLabel(
                              l,
                              c.snapshot!.permissionFor(user.id),
                            ),
                          ),
                          if (user.disabled) Text(l.serverAdminDisabled),
                          if (user.role.name == 'admin')
                            Text(l.serverAdministrator),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}
