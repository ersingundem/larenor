import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;

import '../data/inventory_controller.dart';
import '../domain/inventory_models.dart';

/// Localized copy supplied by the route's AppLocalizations adapter.
final class InventoryStrings {
  const InventoryStrings({
    required this.title,
    required this.manualLabel,
    required this.open,
    required this.emptyTitle,
    required this.emptyBody,
    required this.room,
    required this.device,
    required this.documents,
    required this.grants,
    required this.audit,
    required this.loading,
    required this.accessVerified,
    required this.invalidQr,
    required this.foreignQr,
    required this.offline,
    required this.stale,
    required this.invalidResponse,
  });
  final String title, manualLabel, open, emptyTitle, emptyBody;
  final String room, device, documents, grants, audit;
  final String loading, accessVerified;
  final String invalidQr, foreignQr, offline, stale, invalidResponse;
}

final class InventoryScreen extends StatefulWidget {
  const InventoryScreen({
    super.key,
    required this.controller,
    required this.strings,
  });
  final InventoryController controller;
  final InventoryStrings strings;

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

final class _InventoryScreenState extends State<InventoryScreen> {
  final _manual = TextEditingController();
  final _manualFocus = FocusNode();

  @override
  void dispose() {
    _manual.dispose();
    _manualFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.controller.canResolve) {
      unawaited(widget.controller.resolveManual(_manual.text));
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(middle: Text(widget.strings.title)),
    child: SafeArea(
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          return LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 900;
              final list = _list(context, controller);
              final detail = _detail(context, controller.selected);
              return SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _entry(context),
                    if (controller.busy)
                      Semantics(
                        liveRegion: true,
                        label: widget.strings.loading,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: CupertinoActivityIndicator(),
                        ),
                      ),
                    if (controller.failure case final failure?)
                      Semantics(
                        liveRegion: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(_failure(failure)),
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (compact) ...[
                      list,
                      const SizedBox(height: 20),
                      detail,
                    ] else
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 2, child: list),
                          const SizedBox(width: 24),
                          Expanded(flex: 3, child: detail),
                        ],
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    ),
  );

  Widget _entry(BuildContext context) => Semantics(
    textField: true,
    label: widget.strings.manualLabel,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CupertinoTextField(
          key: const ValueKey('inventory-manual-entry'),
          controller: _manual,
          focusNode: _manualFocus,
          enabled: widget.controller.canResolve,
          placeholder: widget.strings.manualLabel,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => _submit(),
          padding: const EdgeInsets.all(16),
        ),
        const SizedBox(height: 12),
        Semantics(
          button: true,
          label: widget.strings.open,
          child: SizedBox(
            key: const ValueKey('inventory-open'),
            height: 48,
            child: CupertinoButton.filled(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              onPressed: widget.controller.canResolve ? _submit : null,
              child: ExcludeSemantics(child: Text(widget.strings.open)),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _list(BuildContext context, InventoryController controller) {
    if (controller.entries.isEmpty) {
      return _card(
        context,
        Semantics(
          container: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  widget.strings.emptyTitle,
                  style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
                ),
              ),
              const SizedBox(height: 8),
              Text(widget.strings.emptyBody),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in controller.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Semantics(
              button: true,
              selected: identical(entry, controller.selected),
              label: '${entry.item.label}, ${widget.strings.accessVerified}',
              child: CupertinoButton(
                color: CupertinoColors.secondarySystemGroupedBackground
                    .resolveFrom(context),
                padding: const EdgeInsets.all(16),
                alignment: AlignmentDirectional.centerStart,
                onPressed: controller.busy
                    ? null
                    : () => controller.select(entry),
                child: ExcludeSemantics(
                  child: Text(
                    entry.item.label,
                    style: CupertinoTheme.of(context).textTheme.textStyle,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _detail(BuildContext context, InventoryDetail? detail) {
    if (detail == null) return const SizedBox.shrink();
    final item = detail.item;
    return _card(
      context,
      Semantics(
        container: true,
        explicitChildNodes: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                item.label,
                style: CupertinoTheme.of(context)
                    .textTheme
                    .navLargeTitleTextStyle,
              ),
            ),
            const SizedBox(height: 12),
            Semantics(
              label: widget.strings.accessVerified,
              excludeSemantics: true,
              child: Row(
                children: [
                  const Icon(CupertinoIcons.check_mark_circled_solid, size: 22),
                  const SizedBox(width: 8),
                  Expanded(child: Text(widget.strings.accessVerified)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _reference(widget.strings.room, item.links.roomId),
            _reference(widget.strings.device, item.links.deviceId),
            _reference(
              widget.strings.documents,
              item.links.documentIds.isEmpty
                  ? null
                  : item.links.documentIds.join('\n'),
            ),
            _reference(
              widget.strings.grants,
              detail.grants == null
                  ? null
                  : '${detail.grants!.subjectIds.length}',
            ),
            _reference(
              widget.strings.audit,
              '${detail.history.entries.length}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _reference(String label, String? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        SelectableText(value ?? '—'),
      ],
    ),
  );

  Widget _card(BuildContext context, Widget child) => DecoratedBox(
    decoration: BoxDecoration(
      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
        context,
      ),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );

  String _failure(InventoryFailure failure) => switch (failure) {
    InventoryFailure.invalidQr => widget.strings.invalidQr,
    InventoryFailure.foreignQr => widget.strings.foreignQr,
    InventoryFailure.offline => widget.strings.offline,
    InventoryFailure.stale => widget.strings.stale,
    InventoryFailure.invalidResponse => widget.strings.invalidResponse,
  };
}
