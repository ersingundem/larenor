import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/home_session_controller.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../data/home_resources_api.dart';
import '../data/home_resources_controller.dart';
import '../domain/home_resource_models.dart';
import '../domain/home_resource_mutations.dart';

enum _Editor { create, update, delete }

/// Mounted inside SettingsGate; every mutation also rechecks current Core auth.
class HomeResourceAdminScreen extends ConsumerStatefulWidget {
  const HomeResourceAdminScreen({super.key, this.onExit});
  final VoidCallback? onExit;
  @override
  ConsumerState<HomeResourceAdminScreen> createState() => _HomeResourceAdminScreenState();
}

class _HomeResourceAdminScreenState extends ConsumerState<HomeResourceAdminScreen>
    with WidgetsBindingObserver {
  late final HomeResourcesController _controller;
  final _label = TextEditingController(), _order = TextEditingController();
  _Editor? _editor;
  HomeResourceRecord? _target;
  HomeResourceKind _kind = HomeResourceKind.room;
  bool _saving = false, _invalid = false, _foreground = true, _focused = true, _scheduled = false;
  int _generation = 0, _editorEpoch = 0;
  int? _viewId;
  AppInteractionController? _interaction;
  int _interactionEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    _controller = HomeResourcesController(ref.read(homeSessionControllerProvider)!,
        ref.read(homeResourcesApiFactoryProvider), ref.read(homeResourcesClockProvider),
        _current, adminManagement: true)..addListener(_changed);
  }

  bool _windowAvailable() {
    final value = ref.read(windowPolicySnapshotProvider);
    if (value.isLoading || value.hasError || !value.hasValue) return false;
    final window = value.requireValue;
    return !window.supported || window.isResumed && window.hasWindowFocus && !window.isPictureInPicture;
  }
  bool _current() => mounted && _foreground && _focused && _windowAvailable() &&
      (_interaction?.active ?? true) && TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true;

  void _wipe() {
    _generation++;
    _label.clear(); _order.clear();
    _target = null; _editor = null; _saving = false; _invalid = false;
    _kind = HomeResourceKind.room;
  }
  void _changed() {
    if (!mounted) return;
    if (_editor != null && (!_controller.canManage || !_current() ||
        !_saving && _editorEpoch != _controller.epoch)) _wipe();
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
      _interaction = next; _interactionEpoch = next?.epoch ?? 0;
      next?.addListener(_interactionChanged);
    }
    final view = View.of(context).viewId;
    if (_viewId != null && _viewId != view) _wipe();
    _viewId = view;
    TickerMode.valuesOf(context); ModalRoute.of(context);
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
    _retireIfHidden(); setState(() {});
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    _foreground = state == AppLifecycleState.resumed;
    _retireIfHidden(); setState(() {});
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interaction?.removeListener(_interactionChanged);
    _controller.removeListener(_changed);
    _controller.dispose(); _wipe(); _label.dispose(); _order.dispose();
    super.dispose();
  }

  VoidCallback _callback(VoidCallback action) {
    final generation = _generation, epoch = _controller.epoch,
        interactionEpoch = _interaction?.epoch;
    return () {
      if (_current() && generation == _generation && epoch == _controller.epoch &&
          interactionEpoch == _interaction?.epoch) action();
    };
  }
  void _begin(_Editor editor, [HomeResourceRecord? target]) {
    if (!_controller.canMutate || _editor != null) return;
    setState(() {
      _wipe(); _editor = editor; _target = target; _editorEpoch = _controller.epoch;
      _kind = target?.kind ?? HomeResourceKind.room;
      _label.text = target?.label ?? ''; _order.text = '${target?.order ?? 0}';
    });
  }
  Future<void> _submit() async {
    if (_editor == null || _saving || !_controller.canMutate || !_current()) return;
    final editor = _editor!, target = _target, generation = _generation,
        interactionEpoch = _interaction?.epoch;
    HomeResourceMetadata? metadata;
    if (editor != _Editor.delete) {
      try {
        final order = int.tryParse(_order.text);
        if (order == null) throw const FormatException();
        metadata = HomeResourceMetadata(label: _label.text, order: order);
      } catch (_) {
        setState(() => _invalid = true); return;
      }
    }
    bool current() => _current() && generation == _generation &&
        interactionEpoch == _interaction?.epoch && _controller.canManage;
    setState(() {_saving = true; _invalid = false;});
    switch (editor) {
      case _Editor.create:
        await _controller.create(kind: _kind, label: metadata!.label, order: metadata.order, isCurrent: current);
      case _Editor.update:
        await _controller.update(target!, label: metadata!.label, order: metadata.order, isCurrent: current);
      case _Editor.delete:
        await _controller.delete(target!, isCurrent: current);
    }
    if (mounted && generation == _generation) setState(_wipe);
  }

  Widget _button(String key, String label, VoidCallback? action, {bool destructive = false, bool selected = false}) => Semantics(
    selected: selected,
    child: CupertinoButton(
      key: ValueKey(key), minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      onPressed: action == null ? null : _callback(action),
      child: Text(label, textAlign: TextAlign.center,
          style: destructive ? TextStyle(color: CupertinoColors.systemRed.resolveFrom(context)) : null),
    ),
  );
  Widget _field(String key, String label, TextEditingController controller, {bool numeric = false}) {
    final submit = _callback(() => unawaited(_submit()));
    return Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ExcludeSemantics(child: Text(label)), const SizedBox(height: 8),
      Semantics(label: label, child: CupertinoTextField(key: ValueKey(key), controller: controller,
        enabled: !_saving && _current(), padding: const EdgeInsets.all(14),
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        textInputAction: numeric ? TextInputAction.done : TextInputAction.next,
        onSubmitted: numeric ? (_) => submit() : null)),
    ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(windowPolicySnapshotProvider, (_, _) {_retireIfHidden(); if (mounted) setState(() {});});
    _syncLater();
    final l10n = AppLocalizations.of(context);
    final rows = _controller.entries.toList()..sort((a,b) {
      final order = a.order.compareTo(b.order); return order == 0 ? a.id.compareTo(b.id) : order;
    });
    final outcome = _controller.mutationOutcome;
    final message = switch (outcome) {
      HomeResourceMutationOutcome.saved => l10n.homeResourceAdminSaved,
      HomeResourceMutationOutcome.deleted => l10n.homeResourceAdminDeleted,
      HomeResourceMutationOutcome.conflict => l10n.homeResourceAdminConflict,
      HomeResourceMutationOutcome.uncertain => l10n.homeResourceAdminUncertain,
      HomeResourceMutationOutcome.failed => l10n.homeResourceAdminFailed,
      null => null,
    };
    return AppPageScaffold(
      key: const ValueKey('home-resource-admin'),
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.homeResourceAdminTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: _button('home-resource-admin-back', l10n.commonBack, () {
          if (widget.onExit != null) {widget.onExit!();} else {Navigator.of(context).maybePop();}
        }),
      ),
      child: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 880),
        child: !_current() || !_controller.canManage
          ? Padding(padding: const EdgeInsets.all(24), child: Text(l10n.homeResourceAdminRequired))
          : CustomScrollView(slivers: [
            SliverPadding(padding: const EdgeInsets.all(20), sliver: SliverToBoxAdapter(child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Semantics(header: true, child: Text(l10n.homeResourceAdminTitle,
                    style: CupertinoTheme.of(context).textTheme.navTitleTextStyle)),
                const SizedBox(height: 12), Text(l10n.homeResourceAdminDescription),
                if (message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Semantics(liveRegion: true, child: Text(message,
                    key: ValueKey('home-resource-mutation-${outcome!.name}')))),
                if (_controller.busy) Semantics(liveRegion: true, child: Text(
                    _saving ? l10n.homeResourceAdminSaving : l10n.homeResourcesLoading)),
                if (_editor == null) ...[
                  if (_controller.failure != null && message == null) Text(l10n.homeResourcesError),
                  _button('home-resource-admin-refresh',l10n.commonRefresh,
                      _controller.canRefresh ? () => unawaited(_controller.refresh()) : null),
                  _button('home-resource-admin-create',l10n.homeResourceAdminCreate,
                      _controller.canMutate ? () => _begin(_Editor.create) : null),
                  if (_controller.loaded && rows.isEmpty) Text(l10n.homeResourcesEmpty),
                ] else ...[
                  if (_editor == _Editor.delete) ...[
                    Semantics(header: true, child: Text(l10n.homeResourceAdminConfirmDelete,
                        key: const ValueKey('home-resource-delete-confirmation'))),
                    Text(_target!.label), const SizedBox(height: 12), Text(l10n.homeResourceAdminDeleteHint),
                    _button('home-resource-confirm-delete',l10n.commonDelete,
                        _saving ? null : () => unawaited(_submit()), destructive: true),
                  ] else ...[
                    if (_editor == _Editor.create) Wrap(spacing: 12, children: [
                      for (final kind in HomeResourceKind.values)
                        _button('home-resource-kind-${kind.name}',
                          kind == HomeResourceKind.room ? l10n.homeResourcesRoom : l10n.homeResourcesResource,
                          _saving ? null : () => setState(() => _kind = kind), selected: _kind == kind),
                    ]),
                    _field('home-resource-label',l10n.homeResourceAdminLabel,_label),
                    _field('home-resource-order',l10n.homeResourceAdminOrder,_order,numeric:true),
                    if (_invalid) Semantics(liveRegion:true, child:Text(l10n.homeResourceAdminInvalid)),
                    _button('home-resource-save',l10n.commonSave,_saving ? null : () => unawaited(_submit())),
                  ],
                  _button('home-resource-cancel-edit',l10n.commonCancel,_saving ? null : () => setState(_wipe)),
                ],
              ]))),
            if (_editor == null) SliverList.builder(itemCount: rows.length,itemBuilder: (context,index) {
              final row = rows[index];
              return Padding(key: ValueKey('home-resource-admin-row-${row.id}'),padding: const EdgeInsets.fromLTRB(20,0,20,16),
                child: DecoratedBox(decoration: BoxDecoration(color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context),
                  borderRadius: BorderRadius.circular(16)),child: Padding(padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start,children: [
                    Text(row.label,style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(fontWeight: FontWeight.w600)),
                    Text(row.kind == HomeResourceKind.room ? l10n.homeResourcesRoom : l10n.homeResourcesResource),
                    Text('${l10n.homeResourceAdminOrder}: ${row.order}'),
                    Wrap(spacing:12,children:[
                      _button('home-resource-edit-${row.id}',l10n.homeResourceAdminEdit,
                        _controller.canMutate ? () => _begin(_Editor.update,row) : null),
                      _button('home-resource-delete-${row.id}',l10n.commonDelete,
                        _controller.canMutate ? () => _begin(_Editor.delete,row) : null,destructive:true),
                    ]),
                  ]))));
            }),
            if (_editor == null && _controller.nextAfter != null) SliverToBoxAdapter(child:
              _button('home-resource-admin-load-more',l10n.homeResourcesLoadMore,
                _controller.canLoadMore ? () => unawaited(_controller.loadMore()) : null)),
          ]),
      ))),
    );
  }
}
