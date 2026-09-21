import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../data/resource_catalog_controller.dart';
import '../domain/resource_reservation_models.dart';

final class ResourceCatalogScreen extends StatefulWidget {
  const ResourceCatalogScreen({super.key, required this.controller});
  final ResourceCatalogController controller;

  @override
  State<ResourceCatalogScreen> createState() => _ResourceCatalogScreenState();
}

final class _ResourceCatalogScreenState extends State<ResourceCatalogScreen> {
  final _label = TextEditingController();
  final _timezone = TextEditingController(text: 'UTC');
  final _capacity = TextEditingController(text: '1');
  ReservationResource? _selected;
  late int _lease;

  @override
  void initState() {
    super.initState();
    _lease = widget.controller.bind();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    final selected = _selected;
    if (selected != null &&
        !widget.controller.resources.any(
          (item) =>
              item.id == selected.id && item.revision == selected.revision,
        )) {
      _selected = null;
      _label.clear();
      _timezone.text = 'UTC';
      _capacity.text = '1';
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _label.dispose();
    _timezone.dispose();
    _capacity.dispose();
    super.dispose();
  }

  void _select(ReservationResource resource) {
    if (!resource.active ||
        widget.controller.state != ResourceCatalogState.ready) {
      return;
    }
    setState(() {
      _selected = resource;
      _label.text = resource.label;
      _timezone.text = resource.timezone;
      _capacity.text = '${resource.capacity}';
    });
  }

  bool get _valid =>
      _label.text.trim().isNotEmpty &&
      _label.text == _label.text.trim() &&
      _label.text.length <= 80 &&
      _timezone.text.trim().isNotEmpty &&
      _timezone.text.length <= 128 &&
      (int.tryParse(_capacity.text) ?? 0) >= 1 &&
      (int.tryParse(_capacity.text) ?? 65) <= 64;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;
    final state = controller.state;
    final enabled = controller.canManage && state == ResourceCatalogState.ready;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.resourceCatalogTitle),
      ),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            final list = _list(l10n, enabled);
            final form = _form(l10n, enabled);
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(_status(l10n, state)),
                  ),
                  const SizedBox(height: 16),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: list),
                        const SizedBox(width: 20),
                        Expanded(child: form),
                      ],
                    )
                  else ...[
                    list,
                    const SizedBox(height: 20),
                    form,
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _status(AppLocalizations l10n, ResourceCatalogState state) =>
      switch (state) {
        ResourceCatalogState.loading ||
        ResourceCatalogState.busy => l10n.resourceCatalogLoading,
        ResourceCatalogState.offline => l10n.resourceCatalogOffline,
        ResourceCatalogState.uncertain => l10n.resourceCatalogUncertain,
        ResourceCatalogState.error => l10n.resourceCatalogError,
        ResourceCatalogState.ready when !widget.controller.canManage =>
          l10n.resourceCatalogAdminRequired,
        _ => l10n.resourceCatalogSelect,
      };

  Widget _list(AppLocalizations l10n, bool enabled) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      children: [
        for (final resource in widget.controller.resources)
          _CatalogAction(
            key: ValueKey('resource-catalog-${resource.id}'),
            label:
                '${resource.label}, ${resource.timezone}, ${resource.capacity}, '
                '${resource.active ? l10n.resourceCatalogActive : l10n.resourceCatalogInactive}',
            onPressed: enabled && resource.active
                ? () => _select(resource)
                : null,
            child: Row(
              children: [
                Expanded(
                  child: Text(resource.label, textAlign: TextAlign.start),
                ),
                Text('${resource.timezone} · ${resource.capacity}'),
              ],
            ),
          ),
      ],
    ),
  );

  Widget _form(AppLocalizations l10n, bool enabled) => Column(
    children: [
      CupertinoTextField(
        key: const ValueKey('resource-catalog-label'),
        controller: _label,
        placeholder: l10n.resourceCatalogLabel,
        enabled: enabled,
        padding: const EdgeInsets.all(14),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      CupertinoTextField(
        key: const ValueKey('resource-catalog-timezone'),
        controller: _timezone,
        placeholder: l10n.resourceCatalogTimezone,
        enabled: enabled,
        padding: const EdgeInsets.all(14),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      CupertinoTextField(
        key: const ValueKey('resource-catalog-capacity'),
        controller: _capacity,
        placeholder: l10n.resourceCatalogCapacity,
        enabled: enabled,
        keyboardType: TextInputType.number,
        padding: const EdgeInsets.all(14),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 16),
      _CatalogAction(
        key: const ValueKey('resource-catalog-save'),
        label: _selected == null
            ? l10n.resourceCatalogAdd
            : l10n.resourceCatalogUpdate,
        filled: true,
        onPressed: enabled && _valid
            ? () async {
                final selected = _selected;
                if (selected == null) {
                  await widget.controller.create(
                    _lease,
                    label: _label.text,
                    timezone: _timezone.text,
                    capacity: int.parse(_capacity.text),
                  );
                } else {
                  await widget.controller.update(
                    _lease,
                    selected,
                    label: _label.text,
                    timezone: _timezone.text,
                    capacity: int.parse(_capacity.text),
                  );
                }
              }
            : null,
        child: Text(
          _selected == null
              ? l10n.resourceCatalogAdd
              : l10n.resourceCatalogUpdate,
        ),
      ),
      if (_selected case final selected?) ...[
        const SizedBox(height: 12),
        _CatalogAction(
          key: const ValueKey('resource-catalog-deactivate'),
          label: l10n.resourceCatalogDeactivate,
          onPressed:
              enabled &&
                  widget.controller.resources
                          .where((item) => item.active)
                          .length >
                      1
              ? () => widget.controller.deactivate(_lease, selected)
              : null,
          child: Text(l10n.resourceCatalogDeactivate),
        ),
      ],
    ],
  );
}

final class _CatalogAction extends StatelessWidget {
  const _CatalogAction({
    super.key,
    required this.label,
    required this.onPressed,
    required this.child,
    this.filled = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget child;
  final bool filled;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: label,
    onTap: onPressed,
    excludeSemantics: true,
    child: FocusableActionDetector(
      enabled: onPressed != null,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onPressed?.call();
            return null;
          },
        ),
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: filled
            ? CupertinoButton.filled(onPressed: onPressed, child: child)
            : CupertinoButton(onPressed: onPressed, child: child),
      ),
    ),
  );
}
