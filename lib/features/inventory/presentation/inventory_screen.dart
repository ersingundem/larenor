import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/inventory_controller.dart';
import '../data/inventory_scanner.dart';
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
    required this.required,
    required this.scan,
    required this.closeScanner,
    required this.cameraDenied,
    required this.cameraUnavailable,
  });

  factory InventoryStrings.fromLocalizations(AppLocalizations l) =>
      InventoryStrings(
        title: l.inventoryTitle,
        manualLabel: l.inventoryManualLabel,
        open: l.inventoryOpen,
        emptyTitle: l.inventoryEmptyTitle,
        emptyBody: l.inventoryEmptyBody,
        room: l.inventoryRoom,
        device: l.inventoryDevice,
        documents: l.inventoryDocuments,
        grants: l.inventoryGrants,
        audit: l.inventoryAudit,
        loading: l.inventoryLoading,
        accessVerified: l.inventoryAccessVerified,
        invalidQr: l.inventoryInvalidQr,
        foreignQr: l.inventoryForeignQr,
        offline: l.inventoryOffline,
        stale: l.inventoryStale,
        invalidResponse: l.inventoryInvalidResponse,
        required: l.inventoryRequired,
        scan: l.inventoryScan,
        closeScanner: l.inventoryCloseScanner,
        cameraDenied: l.inventoryCameraDenied,
        cameraUnavailable: l.inventoryCameraUnavailable,
      );
  final String title, manualLabel, open, emptyTitle, emptyBody;
  final String room, device, documents, grants, audit;
  final String loading, accessVerified;
  final String invalidQr, foreignQr, offline, stale, invalidResponse;
  final String required, scan, closeScanner, cameraDenied, cameraUnavailable;
}

final class InventoryScreen extends StatefulWidget {
  const InventoryScreen({
    super.key,
    required this.controller,
    required this.strings,
    this.scanner,
  });
  final InventoryController controller;
  final InventoryStrings strings;
  final InventoryScannerController? scanner;

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

final class _InventoryScreenState extends State<InventoryScreen>
    with WidgetsBindingObserver {
  final _manual = TextEditingController();
  final _manualFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(widget.scanner?.onLifecycle(state));
  }

  @override
  void didChangeMetrics() {
    unawaited(widget.scanner?.onRotation());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
  Widget build(BuildContext context) => AppPageScaffold(
    navigationBar: CupertinoNavigationBar(middle: Text(widget.strings.title)),
    child: SafeArea(
      child: ListenableBuilder(
        listenable: Listenable.merge([
          widget.controller,
          if (widget.scanner != null) widget.scanner!,
        ]),
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
                    if (widget.scanner?.opened == true) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        key: const ValueKey('inventory-camera-preview'),
                        height: 320,
                        child: widget.scanner!.preview,
                      ),
                    ],
                    if (widget.scanner?.failure case final cameraFailure?)
                      Semantics(
                        liveRegion: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            cameraFailure ==
                                    InventoryCameraFailure.permissionDenied
                                ? widget.strings.cameraDenied
                                : widget.strings.cameraUnavailable,
                          ),
                        ),
                      ),
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

  Widget _entry(BuildContext context) => SettingsSection(
    header: Text(widget.strings.manualLabel),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Semantics(
          textField: true,
          label: widget.strings.manualLabel,
          child: CupertinoTextField(
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
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: widget.strings.open,
                child: SizedBox(
                  key: const ValueKey('inventory-open'),
                  height: 48,
                  child: CupertinoButton.filled(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    onPressed: widget.controller.canResolve ? _submit : null,
                    child: ExcludeSemantics(child: Text(widget.strings.open)),
                  ),
                ),
              ),
            ),
            if (widget.scanner != null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  key: const ValueKey('inventory-scan'),
                  height: 48,
                  child: CupertinoButton(
                    minimumSize: const Size(48, 48),
                    color: CupertinoColors.secondarySystemGroupedBackground
                        .resolveFrom(context),
                    onPressed: widget.scanner!.opened
                        ? () => unawaited(widget.scanner!.close())
                        : widget.scanner!.canOpen
                        ? () => unawaited(widget.scanner!.open())
                        : null,
                    child: Text(
                      widget.scanner!.opened
                          ? widget.strings.closeScanner
                          : widget.strings.scan,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ],
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
          SettingsActionTile(
            buttonKey: ValueKey('inventory-item-${entry.item.id}'),
            selected: identical(entry, controller.selected),
            title: Text(entry.item.label),
            additionalInfo: Text(widget.strings.accessVerified),
            onTap: controller.busy ? null : () => controller.select(entry),
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
