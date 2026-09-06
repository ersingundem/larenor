import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../settings/presentation/settings_gate_screen.dart';
import '../data/home_people_controller.dart';
import '../data/home_people_providers.dart';
import '../domain/home_person_models.dart';
import 'home_people_route.dart';
import 'home_people_widgets.dart';
import 'home_person_grants_screen.dart';

/// Explicit entry only: building the Core home never instantiates a person API.
class HomePeopleEntry extends ConsumerStatefulWidget {
  const HomePeopleEntry({super.key});
  @override
  ConsumerState<HomePeopleEntry> createState() => _HomePeopleEntryState();
}

class _HomePeopleEntryState extends ConsumerState<HomePeopleEntry> {
  int _windowEpoch = 0;
  @override
  Widget build(BuildContext context) {
    ref.watch(windowPolicySnapshotProvider);
    ref.listen(windowPolicySnapshotProvider, (_, _) => _windowEpoch++);
    final home = ref.watch(homeSessionControllerProvider)!;
    final interaction = AppInteractionScope.maybeOf(context),
        container = ProviderScope.containerOf(context, listen: false);
    return ListenableBuilder(
      listenable: home,
      builder: (_, _) {
        final session = home.account.session,
            generation = home.account.generation,
            epoch = interaction?.epoch,
            windowEpoch = _windowEpoch;
        var retired = false;
        bool current() {
          if (retired) return false;
          try {
            final state = ref.read(windowPolicySnapshotProvider);
            final windowCurrent =
                !state.isLoading &&
                !state.hasError &&
                state.hasValue &&
                (!state.requireValue.supported ||
                    state.requireValue.isResumed &&
                        state.requireValue.hasWindowFocus &&
                        !state.requireValue.isPictureInPicture);
            final valid =
                context.mounted &&
                windowCurrent &&
                windowEpoch == _windowEpoch &&
                identical(
                  ProviderScope.containerOf(context, listen: false),
                  container,
                ) &&
                identical(ref.read(homeSessionControllerProvider), home) &&
                home.source == HomeSource.verifiedCore &&
                !home.busy &&
                home.failure == null &&
                home.interaction.active &&
                home.account.isCurrent(generation) &&
                !home.account.working &&
                !home.account.hasPendingContext &&
                identical(home.account.session, session) &&
                session?.context != null &&
                session?.user.mustChangePassword == false &&
                !session!.expiresSoon(ref.read(homePeopleClockProvider)()) &&
                (interaction?.active ?? false) &&
                interaction?.epoch == epoch &&
                TickerMode.valuesOf(context).enabled &&
                ModalRoute.of(context)?.isCurrent == true;
            if (!valid) retired = true;
            return valid;
          } catch (_) {
            retired = true;
            return false;
          }
        }

        return SettingsActionTile(
          key: const ValueKey('home-people-entry'),
          title: Text(AppLocalizations.of(context).homePeopleTitle),
          onTap: !current()
              ? null
              : () {
                  if (current()) {
                    Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => const HomePeopleScreen(),
                      ),
                    );
                  }
                },
        );
      },
    );
  }
}

class HomePeopleScreen extends StatelessWidget {
  const HomePeopleScreen({
    super.key,
    this.adminManagement = false,
    this.gateCurrent,
    this.onExit,
  }) : assert(!adminManagement || gateCurrent != null);
  final bool adminManagement;
  final bool Function()? gateCurrent;
  final VoidCallback? onExit;
  @override
  Widget build(BuildContext context) => HomePeopleRoute(
    title: adminManagement
        ? AppLocalizations.of(context).homePeopleManage
        : AppLocalizations.of(context).homePeopleTitle,
    gateCurrent: gateCurrent ?? () => true,
    onExit: onExit,
    builder: (owner) => _PeopleContent(
      owner: owner,
      admin: adminManagement,
      gateCurrent: gateCurrent ?? () => true,
      onExit: onExit,
    ),
  );
}

enum _Editor { create, update, delete }

class _PeopleContent extends ConsumerStatefulWidget {
  const _PeopleContent({
    required this.owner,
    required this.admin,
    required this.gateCurrent,
    this.onExit,
  });
  final HomePeopleOwner owner;
  final bool admin;
  final bool Function() gateCurrent;
  final VoidCallback? onExit;
  @override
  ConsumerState<_PeopleContent> createState() => _PeopleContentState();
}

class _PeopleContentState extends ConsumerState<_PeopleContent> {
  late final _selection = (
    owner: widget.owner,
    adminManagement: widget.admin,
    pageSize: 25,
  );
  late final HomePeopleController _controller;
  final _label = TextEditingController(), _order = TextEditingController();
  _Editor? _editor;
  HomePersonRecord? _target;
  bool _saving = false, _invalid = false;
  int _generation = 0, _editorEpoch = 0;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(homePeopleControllerProvider(_selection))
      ..addListener(_changed);
  }

  bool _current() => mounted && widget.owner.isCurrent;
  void _wipe() {
    _generation++;
    _label.clear();
    _order.clear();
    _editor = null;
    _target = null;
    _saving = false;
    _invalid = false;
  }

  void _changed() {
    if (!mounted) return;
    if (_editor != null &&
        (!_controller.fresh ||
            !_current() ||
            !_saving && _editorEpoch != _controller.epoch))
      _wipe();
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _wipe();
    _label.dispose();
    _order.dispose();
    super.dispose();
  }

  VoidCallback _callback(VoidCallback action) {
    final generation = _generation, epoch = _controller.epoch;
    return () {
      if (_current() && generation == _generation && epoch == _controller.epoch)
        action();
    };
  }

  Widget _button(
    String key,
    String label,
    VoidCallback? action, {
    bool destructive = false,
    String? semanticLabel,
  }) => PeopleButton(
    key: ValueKey(key),
    label: label,
    semanticLabel: semanticLabel,
    onPressed: action == null ? null : _callback(action),
    destructive: destructive,
  );
  void _begin(_Editor editor, [HomePersonRecord? target]) {
    if (!_controller.canMutate || _editor != null) return;
    setState(() {
      _wipe();
      _editor = editor;
      _target = target;
      _editorEpoch = _controller.epoch;
      _label.text = target?.label ?? '';
      _order.text = '${target?.order ?? 0}';
    });
  }

  Future<void> _submit() async {
    if (_editor == null || _saving || !_current() || !_controller.canMutate)
      return;
    final editor = _editor!, target = _target, generation = _generation;
    HomePersonMetadata? desired;
    if (editor != _Editor.delete) {
      try {
        final order = int.tryParse(_order.text);
        if (order == null) throw const FormatException();
        desired = HomePersonMetadata(label: _label.text, order: order);
      } catch (_) {
        setState(() => _invalid = true);
        return;
      }
    }
    bool current() =>
        _current() && generation == _generation && _controller.canManage;
    setState(() {
      _saving = true;
      _invalid = false;
    });
    switch (editor) {
      case _Editor.create:
        await _controller.create(
          label: desired!.label,
          order: desired.order,
          isCurrent: current,
        );
      case _Editor.update:
        await _controller.update(
          target!,
          label: desired!.label,
          order: desired.order,
          isCurrent: current,
        );
      case _Editor.delete:
        await _controller.delete(target!, isCurrent: current);
    }
    if (mounted && generation == _generation) setState(_wipe);
  }

  Widget _field(
    String key,
    String label,
    TextEditingController value, {
    bool numeric = false,
  }) {
    final submit = _callback(() => unawaited(_submit()));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(child: Text(label)),
          const SizedBox(height: 8),
          Semantics(
            label: label,
            child: CupertinoTextField(
              key: ValueKey(key),
              controller: value,
              enabled: !_saving && _current(),
              padding: const EdgeInsets.all(14),
              keyboardType: numeric ? TextInputType.number : TextInputType.text,
              textInputAction: numeric
                  ? TextInputAction.done
                  : TextInputAction.next,
              onSubmitted: numeric ? (_) => submit() : null,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(homePeopleControllerProvider(_selection));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.setVisible(_current());
    });
    final l = AppLocalizations.of(context),
        c = _controller,
        rows = c.entries.toList()
          ..sort((a, b) {
            final order = a.order.compareTo(b.order);
            return order == 0 ? a.id.compareTo(b.id) : order;
          });
    final message = switch (c.mutationOutcome) {
      HomePersonMutationOutcome.saved => l.homePeopleSaved,
      HomePersonMutationOutcome.deleted => l.homePeopleDeleted,
      HomePersonMutationOutcome.conflict => l.homePeopleConflict,
      HomePersonMutationOutcome.uncertain => l.homePeopleUncertain,
      HomePersonMutationOutcome.failed => l.homePeopleFailed,
      null => null,
    };
    final available = _current() && (widget.admin ? c.canManage : c.fresh);
    return PeoplePage(
      key: ValueKey(widget.admin ? 'home-people-admin' : 'home-people-list'),
      title: widget.admin ? l.homePeopleManage : l.homePeopleTitle,
      onBack: _callback(
        () => widget.onExit != null
            ? widget.onExit!()
            : Navigator.of(context).maybePop(),
      ),
      slivers: [
        peopleBlock([
          if (!available) ...[
            Text(
              widget.admin ? l.homePeopleAdminRequired : l.homePeopleRequired,
            ),
            if (c.canRefresh)
              _button(
                'home-people-refresh',
                l.commonRefresh,
                () => unawaited(c.refresh()),
              ),
          ] else ...[
            Text(
              widget.admin
                  ? l.homePeopleAdminDescription
                  : l.homePeopleDescription,
            ),
            const SizedBox(height: 12),
            if (message != null)
              peopleMessage('home-people-${c.mutationOutcome!.name}', message),
            if (c.busy)
              peopleMessage(
                'home-people-loading',
                _saving ? l.homePeopleSaving : l.homePeopleLoading,
              ),
            if (_editor == null) ...[
              if (c.failure != null && message == null)
                peopleMessage('home-people-error', l.homePeopleError),
              _button(
                'home-people-refresh',
                l.commonRefresh,
                c.canRefresh ? () => unawaited(c.refresh()) : null,
              ),
              if (widget.admin)
                _button(
                  'home-people-create',
                  l.homePeopleCreate,
                  c.canMutate ? () => _begin(_Editor.create) : null,
                )
              else if (c.canManage)
                _button(
                  'home-people-manage',
                  l.homePeopleManage,
                  () => Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                      builder: (_) => const SettingsGateScreen(
                        initialDestination: SettingsGateDestination.homePeople,
                      ),
                    ),
                  ),
                ),
              if (c.loaded && rows.isEmpty)
                peopleMessage('home-people-empty', l.homePeopleEmpty),
            ] else ...[
              if (_editor == _Editor.delete) ...[
                Semantics(
                  header: true,
                  child: Text(
                    l.homePeopleConfirmDelete,
                    key: const ValueKey('home-people-delete-confirmation'),
                  ),
                ),
                const SizedBox(height: 12),
                Text(_target!.label),
                const SizedBox(height: 12),
                Text(l.homePeopleDeleteHint),
                _button(
                  'home-people-confirm-delete',
                  l.commonDelete,
                  _saving ? null : () => unawaited(_submit()),
                  destructive: true,
                ),
              ] else ...[
                _field('home-people-label', l.homePeopleLabel, _label),
                _field(
                  'home-people-order',
                  l.homePeopleOrder,
                  _order,
                  numeric: true,
                ),
                if (_invalid)
                  peopleMessage('home-people-invalid', l.homePeopleInvalid),
                _button(
                  'home-people-save',
                  l.commonSave,
                  _saving ? null : () => unawaited(_submit()),
                ),
              ],
              _button(
                'home-people-cancel-edit',
                l.commonCancel,
                _saving ? null : () => setState(_wipe),
              ),
            ],
          ],
        ]),
        if (available && _editor == null)
          SliverList.builder(
            itemCount: rows.length,
            findChildIndexCallback: (key) {
              final index = rows.indexWhere(
                (r) => key == ValueKey('home-people-row-${r.id}'),
              );
              return index < 0 ? null : index;
            },
            itemBuilder: (context, index) {
              final row = rows[index];
              return Padding(
                key: ValueKey('home-people-row-${row.id}'),
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: SettingsSection(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            row.label,
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(fontWeight: FontWeight.w600),
                          ),
                          if (widget.admin) ...[
                            Text('${l.homePeopleOrder}: ${row.order}'),
                            Wrap(
                              spacing: 12,
                              children: [
                                _button(
                                  'home-people-edit-${row.id}',
                                  l.commonEdit,
                                  c.canMutate
                                      ? () => _begin(_Editor.update, row)
                                      : null,
                                  semanticLabel: l.homePeopleEditPerson(
                                    row.label,
                                  ),
                                ),
                                _button(
                                  'home-people-grants-${row.id}',
                                  l.homePeopleGrantsTitle,
                                  c.canMutate
                                      ? () => Navigator.of(context).push(
                                          CupertinoPageRoute<void>(
                                            builder: (_) =>
                                                HomePersonGrantsScreen(
                                                  target: row,
                                                  gateCurrent:
                                                      widget.gateCurrent,
                                                ),
                                          ),
                                        )
                                      : null,
                                  semanticLabel: l.homePeopleGrantPerson(
                                    row.label,
                                  ),
                                ),
                                _button(
                                  'home-people-delete-${row.id}',
                                  l.commonDelete,
                                  c.canMutate
                                      ? () => _begin(_Editor.delete, row)
                                      : null,
                                  destructive: true,
                                  semanticLabel: l.homePeopleDeletePerson(
                                    row.label,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        if (available && _editor == null && c.nextAfter != null)
          peopleBlock([
            _button(
              'home-people-load-more',
              l.homePeopleLoadMore,
              c.canLoadMore ? () => unawaited(c.loadMore()) : null,
            ),
          ]),
      ],
    );
  }
}
