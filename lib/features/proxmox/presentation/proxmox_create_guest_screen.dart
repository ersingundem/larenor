import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/models/proxmox_guest.dart';
import '../data/models/proxmox_storage.dart';
import '../providers/proxmox_providers.dart';
import 'widgets/proxmox_guest_type_label.dart';
import 'proxmox_session_guard.dart';
import 'proxmox_mutation_support.dart';

/// Template picker → target storage/new id/name → clone → poll the
/// resulting task until it finishes. Proxmox's own convention is that a
/// "template" is a VM/container clone source, so cloning an existing
/// template is the create-from-template mechanism (see `ProxmoxClient`).
class ProxmoxCreateGuestScreen extends ConsumerStatefulWidget {
  const ProxmoxCreateGuestScreen({
    super.key,
    required this.nodeName,
    this.sourceCurrent,
  });

  final String nodeName;
  final bool Function()? sourceCurrent;
  @override
  ConsumerState<ProxmoxCreateGuestScreen> createState() =>
      _ProxmoxCreateGuestScreenState();
}

class _ProxmoxCreateGuestScreenState
    extends ProxmoxSessionState<ProxmoxCreateGuestScreen> {
  bool _opening = false;
  String get nodeName => widget.nodeName;
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent?.call() ?? true;

  Future<void> _openTemplate(
    ProxmoxSessionLease lease,
    ProxmoxGuest template,
  ) async {
    if (_opening ||
        !isSessionCurrent(lease) ||
        !template.isTemplate ||
        template.node != nodeName) {
      return;
    }
    setState(() => _opening = true);
    final sourceCurrent = captureProxmoxRouteSource(ref);
    if (sourceCurrent == null) {
      setState(() => _opening = false);
      return;
    }
    final upstreamCurrent = widget.sourceCurrent;
    final node = nodeName;
    try {
      await Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (_) => _CloneFormScreen(
            nodeName: node,
            template: template,
            sourceCurrent: () =>
                sourceCurrent() && upstreamCurrent?.call() != false,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchProxmoxSession();
    final guestsAsync = sessionAvailable
        ? ref.watch(proxmoxGuestsProvider(nodeName))
        : null;
    final lease = captureSession();

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          AppLocalizations.of(context).proxmoxCreateFromTemplateTitle,
        ),
      ),
      child: SafeArea(
        child: !sessionAvailable
            ? Center(
                child: Text(AppLocalizations.of(context).proxmoxSessionExpired),
              )
            : guestsAsync!.when(
                skipLoadingOnRefresh: false,
                skipLoadingOnReload: false,
                skipError: false,
                loading: () =>
                    const Center(child: CupertinoActivityIndicator()),
                error: (error, _) => Center(
                  child: Text(AppLocalizations.of(context).healthReadError),
                ),
                data: (guests) {
                  final templates = guests.where((g) => g.isTemplate).toList();
                  if (templates.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          AppLocalizations.of(context).proxmoxNoTemplates,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  return ListView(
                    children: [
                      const SizedBox(height: 16),
                      CupertinoListSection.insetGrouped(
                        children: [
                          for (final template in templates)
                            CupertinoListTile(
                              title: Text(template.name),
                              subtitle: Text(
                                '${proxmoxGuestTypeLabel(context, template.type)} #${template.vmid}',
                              ),
                              trailing: const CupertinoListTileChevron(),
                              onTap: _opening || lease == null
                                  ? null
                                  : () => _openTemplate(lease, template),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _CloneFormScreen extends ConsumerStatefulWidget {
  const _CloneFormScreen({
    required this.nodeName,
    required this.template,
    required this.sourceCurrent,
  });

  final String nodeName;
  final ProxmoxGuest template;
  final bool Function() sourceCurrent;

  @override
  ConsumerState<_CloneFormScreen> createState() => _CloneFormScreenState();
}

class _CloneFormScreenState extends ProxmoxSessionState<_CloneFormScreen> {
  final _idController = TextEditingController();
  late final _nameController = TextEditingController(
    text: '${widget.template.name}-clone',
  );
  bool _fullClone = true;
  ProxmoxStorage? _storage;
  bool _cloning = false;
  bool _pickingStorage = false;
  bool _needsReview = false;
  bool _sent = false;
  Route<dynamic>? _modal;
  @override
  bool sourceSessionCurrent() => widget.sourceCurrent();
  @override
  void onSessionInvalidated() {
    _idController.clear();
    _nameController.clear();
    _storage = null;
    _status = null;
    if (_sent) _needsReview = true;
    final route = _modal;
    _modal = null;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _suggestId();
  }

  Future<void> _suggestId() async {
    try {
      final lease = await readSessionClient(requireCurrentRoute: false);
      if (lease == null) return;
      final nextId = await lease.client.getNextGuestId();
      if (isSessionCurrent(lease, requireCurrentRoute: false) &&
          _idController.text.isEmpty) {
        _idController.text = '$nextId';
      }
    } catch (_) {
      // Cluster ID allocation is optional; an explicitly entered ID works too.
    }
  }

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickStorage(
    ProxmoxSessionLease lease,
    List<ProxmoxStorage> storages,
  ) async {
    if (_cloning ||
        _pickingStorage ||
        _needsReview ||
        !isSessionCurrent(lease)) {
      return;
    }
    setState(() => _pickingStorage = true);
    final l10n = AppLocalizations.of(context);
    final route = CupertinoModalPopupRoute<ProxmoxStorage>(
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.proxmoxTargetStorageTitle),
        actions: [
          for (final storage in storages)
            CupertinoActionSheetAction(
              onPressed: () => closeProxmoxModal(context, storage),
              child: Text(storage.name),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => closeProxmoxModal(context),
          child: Text(l10n.commonCancel),
        ),
      ),
    );
    _modal = route;
    try {
      final picked = await Navigator.of(context).push<ProxmoxStorage>(route);
      if (picked != null && isSessionCurrent(lease)) {
        final current = ref.read(proxmoxStoragesProvider(widget.nodeName));
        if (!current.isLoading &&
            !current.hasError &&
            current.value?.any(
                  (item) =>
                      item.name == picked.name &&
                      item.supportsGuestType(widget.template.type),
                ) ==
                true) {
          setState(() => _storage = picked);
        }
      }
    } finally {
      if (identical(_modal, route)) _modal = null;
      if (mounted) setState(() => _pickingStorage = false);
    }
  }

  Future<void> _submit(ProxmoxSessionLease lease) async {
    if (_cloning ||
        _pickingStorage ||
        _needsReview ||
        !isSessionCurrent(lease)) {
      return;
    }
    final newId = int.tryParse(_idController.text.trim());
    final l10n = AppLocalizations.of(context);
    if (newId == null ||
        newId < 100 ||
        newId > 999999999 ||
        newId == widget.template.vmid) {
      setState(() => _error = l10n.proxmoxErrorInvalidId);
      return;
    }
    final node = widget.nodeName;
    final template = widget.template;
    final name = _nameController.text.trim();
    final full = _fullClone;
    final storage = _storage?.name;
    final storages = ref.read(proxmoxStoragesProvider(node));
    if (full &&
        storage != null &&
        (storages.isLoading ||
            storages.hasError ||
            storages.value?.any(
                  (item) =>
                      item.name == storage &&
                      item.supportsGuestType(template.type),
                ) !=
                true)) {
      return;
    }
    setState(() {
      _cloning = true;
      _error = null;
      _status = l10n.proxmoxCloningStatus;
    });
    var accepted = false;
    _sent = true;
    try {
      final upid = await lease.client.cloneGuest(
        node,
        template.type,
        template.vmid,
        newId: newId,
        name: name.isEmpty ? null : name,
        targetStorage: full ? storage : null,
        full: full,
      );
      accepted = true;
      if (!isSessionCurrent(lease)) {
        _needsReview = true;
        return;
      }
      setState(() => _status = l10n.actionAccepted);
      final result = await lease.client.waitForTask(
        node,
        upid,
        shouldContinue: () => isSessionCurrent(lease),
      );
      if (!isSessionCurrent(lease)) {
        _needsReview = true;
        return;
      }
      if (result?.isSuccess != true) {
        setState(() => _needsReview = true);
        return;
      }
      ref.invalidate(proxmoxGuestsProvider(node));
      ref.invalidate(proxmoxTasksProvider(node));
      if (mounted) closeProxmoxModal(context);
    } catch (error) {
      if (accepted || proxmoxMutationMayHaveRun(error)) _needsReview = true;
      if (isSessionCurrent(lease)) {
        setState(
          () => _error = proxmoxMutationFailureLabel(
            l10n,
            error,
            accepted: accepted,
          ),
        );
      }
    } finally {
      _sent = false;
      if (mounted) setState(() => _cloning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchProxmoxSession();
    final storagesAsync = sessionAvailable
        ? ref.watch(proxmoxStoragesProvider(widget.nodeName))
        : null;
    final lease = captureSession();
    final enabled =
        sessionAvailable &&
        lease != null &&
        !_cloning &&
        !_pickingStorage &&
        !_needsReview;

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          AppLocalizations.of(context).proxmoxCloneTitle(widget.template.name),
        ),
      ),
      child: SafeArea(
        child: !sessionAvailable
            ? Center(
                child: Text(AppLocalizations.of(context).proxmoxSessionExpired),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  const SizedBox(height: 16),
                  CupertinoListSection.insetGrouped(
                    children: [
                      CupertinoTextFormFieldRow(
                        controller: _idController,
                        readOnly: !enabled,
                        prefix: Text(
                          AppLocalizations.of(context).proxmoxNewIdLabel,
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      CupertinoTextFormFieldRow(
                        controller: _nameController,
                        readOnly: !enabled,
                        prefix: Text(
                          AppLocalizations.of(context).proxmoxFieldName,
                        ),
                      ),
                      CupertinoListTile(
                        title: Text(
                          AppLocalizations.of(context).proxmoxFullClone,
                        ),
                        subtitle: Text(
                          AppLocalizations.of(context).proxmoxFullCloneHint,
                        ),
                        trailing: CupertinoSwitch(
                          value: _fullClone,
                          onChanged: enabled
                              ? (value) {
                                  if (isSessionCurrent(lease)) {
                                    setState(() => _fullClone = value);
                                  }
                                }
                              : null,
                        ),
                      ),
                      storagesAsync!.when(
                        skipLoadingOnRefresh: false,
                        skipLoadingOnReload: false,
                        skipError: false,
                        loading: () => CupertinoListTile(
                          title: Text(
                            AppLocalizations.of(context).proxmoxStorageLabel,
                          ),
                          trailing: const CupertinoActivityIndicator(),
                        ),
                        error: (error, _) => CupertinoListTile(
                          title: Text(
                            AppLocalizations.of(context).proxmoxStorageLabel,
                          ),
                          subtitle: Text(
                            AppLocalizations.of(context).healthReadError,
                          ),
                          trailing: CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: enabled
                                ? () {
                                    if (isSessionCurrent(lease)) {
                                      ref.invalidate(
                                        proxmoxStoragesProvider(
                                          widget.nodeName,
                                        ),
                                      );
                                    }
                                  }
                                : null,
                            child: const Icon(CupertinoIcons.refresh),
                          ),
                        ),
                        data: (storages) {
                          final targetable = storages
                              .where(
                                (s) =>
                                    s.supportsGuestType(widget.template.type),
                              )
                              .toList();
                          _storage ??= targetable.isEmpty
                              ? null
                              : targetable.first;
                          return CupertinoListTile(
                            title: Text(
                              AppLocalizations.of(context).proxmoxStorageLabel,
                            ),
                            additionalInfo: Text(
                              _storage?.name ??
                                  AppLocalizations.of(context).commonNone,
                            ),
                            trailing: const CupertinoListTileChevron(),
                            onTap: !_fullClone || !enabled || targetable.isEmpty
                                ? null
                                : () => _pickStorage(lease, targetable),
                          );
                        },
                      ),
                    ],
                  ),
                  if (_status != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(_status!, textAlign: TextAlign.center),
                    ),
                  if (_error != null || _needsReview)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        _needsReview
                            ? AppLocalizations.of(context).proxmoxActionUnknown
                            : _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: CupertinoColors.systemRed.resolveFrom(context),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: CupertinoButton.filled(
                      onPressed: enabled ? () => _submit(lease) : null,
                      child: _cloning
                          ? const CupertinoActivityIndicator(
                              color: CupertinoColors.white,
                            )
                          : Text(AppLocalizations.of(context).commonCreate),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
