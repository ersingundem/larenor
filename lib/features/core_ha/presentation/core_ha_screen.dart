import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../../server/services/domain/server_service_models.dart';
import '../data/core_ha_controller.dart';
import '../data/core_ha_providers.dart';
import '../domain/core_ha_models.dart';
import 'core_ha_route.dart';
import 'core_ha_widgets.dart';

class CoreHaScreen extends StatelessWidget {
  const CoreHaScreen({super.key, required this.target});
  final HomeResourceRecord target;
  @override
  Widget build(BuildContext context) => CoreHaRoute(
    title: AppLocalizations.of(context).coreHaTitle,
    gateCurrent: () => true,
    builder: (owner) => _View(owner: owner, target: target, admin: false),
  );
}

class CoreHaBindingScreen extends StatelessWidget {
  const CoreHaBindingScreen({
    super.key,
    required this.target,
    required this.gateCurrent,
  });
  final HomeResourceRecord target;
  final bool Function() gateCurrent;
  @override
  Widget build(BuildContext context) => CoreHaRoute(
    title: AppLocalizations.of(context).coreHaBindingTitle,
    gateCurrent: gateCurrent,
    builder: (owner) => _View(owner: owner, target: target, admin: true),
  );
}

class _View extends ConsumerStatefulWidget {
  const _View({required this.owner, required this.target, required this.admin});
  final CoreHaOwner owner;
  final HomeResourceRecord target;
  final bool admin;
  @override
  ConsumerState<_View> createState() => _ViewState();
}

class _ViewState extends ConsumerState<_View> {
  late final CoreHaSelection _selection = (
    owner: widget.owner,
    target: widget.target,
    admin: widget.admin,
  );
  late final CoreHaController _controller;
  final _entity = TextEditingController();
  ServerService? _service;
  int _generation = 0;
  bool _invalidEntity = false;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(coreHaControllerProvider(_selection));
    _controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_live()) _controller.setVisible(true);
    });
  }

  bool _live() => mounted && widget.owner.isCurrent;
  void _changed() {
    if (!_controller.fresh || _controller.record == null) {
      _entity.clear();
      _service = null;
      _invalidEntity = false;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _entity.dispose();
    super.dispose();
  }

  String _state(CoreHaProjection p, AppLocalizations l) =>
      switch (p.switchState) {
        CoreHaSwitchState.on => l.coreHaStateOn,
        CoreHaSwitchState.off => l.coreHaStateOff,
        CoreHaSwitchState.unavailable => l.coreHaUnavailable,
        null => switch (p.rawState) {
          'unknown' => l.commonUnknown,
          'unavailable' => l.coreHaUnavailable,
          _ => p.rawState,
        },
      };
  String _error(String? code, AppLocalizations l) => switch (code) {
    'not_found' => l.coreHaNoState,
    'forbidden' => l.coreHaPermission,
    'ha_upstream_unauthorized' => l.coreHaUpstreamAuth,
    'ha_upstream_unavailable' ||
    'connection_failed' ||
    'timeout' => l.coreHaOffline,
    'ha_projection_unsupported' => l.coreHaUnsupported,
    'ha_binding_changed' || 'revision_conflict' => l.coreHaChanged,
    'ha_preview_invalid' => l.coreHaPreviewExpired,
    'ha_command_conflict' => l.coreHaCommandConflict,
    'invalid_request' => l.coreHaInvalidEntity,
    _ => l.coreHaError,
  };
  String _commandState(CoreHaCommandReceipt value, AppLocalizations l) =>
      switch (value.dispatchState) {
        CoreHaDispatchState.pending => l.coreHaCommandPending,
        CoreHaDispatchState.accepted => l.coreHaCommandAccepted,
        CoreHaDispatchState.rejected => l.coreHaCommandRejected,
        CoreHaDispatchState.unknown => l.coreHaCommandUnknown,
      };
  Widget _message(String key, String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Semantics(liveRegion: true, child: Text(label, key: ValueKey(key))),
  );
  @override
  Widget build(BuildContext context) {
    ref.watch(coreHaControllerProvider(_selection));
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (_, _) {
        final c = _controller,
            generation = _generation,
            epoch = _controller.epoch;
        bool ownerCurrent() => _live() && generation == _generation;
        VoidCallback? callback(VoidCallback? action) =>
            action == null || !ownerCurrent()
            ? null
            : () {
                if (ownerCurrent() && epoch == c.epoch) action();
              };
        Widget button(
          String key,
          String label,
          VoidCallback? action, {
          bool? selected,
        }) => CoreHaButton(
          key: ValueKey(key),
          label: label,
          onPressed: callback(action),
          selected: selected,
          isCurrent: ownerCurrent,
        );
        final record = c.fresh ? c.record : null, preview = c.preview;
        final service = _service;
        return CoreHaPage(
          key: ValueKey(widget.admin ? 'core-ha-binding' : 'core-ha-snapshot'),
          title: widget.admin ? l.coreHaBindingTitle : l.coreHaTitle,
          onBack: callback(() => Navigator.of(context).maybePop()),
          slivers: [
            coreHaBlock([
              if (record != null)
                Semantics(
                  container: true,
                  header: true,
                  child: Text(
                    record.label,
                    style: CupertinoTheme.of(context)
                        .textTheme
                        .navTitleTextStyle,
                  ),
                ),
              button(
                'core-ha-refresh',
                l.commonRefresh,
                c.canRefresh ? () => unawaited(c.refresh()) : null,
              ),
              if (c.busy) _message('core-ha-loading', l.coreHaLoading),
              if (!c.fresh && !c.busy)
                _message('core-ha-required', l.coreHaRequired),
              if (c.uncertain)
                _message(
                  'core-ha-uncertain',
                  c.pendingCommandId == null
                      ? l.coreHaUncertain
                      : l.coreHaCommandUncertain,
                )
              else if (c.failure != null)
                _message('core-ha-error', _error(c.failure, l)),
              if (c.stale)
                _message(
                  'core-ha-stale',
                  widget.admin ? l.coreHaPreviewExpired : l.coreHaStale,
                ),
              if (c.saved) _message('core-ha-saved', l.coreHaSaved),
              if (!widget.admin) ...[
                if (c.snapshot != null && c.fresh)
                  _message(
                    'core-ha-state-${c.snapshot!.projection.switchState?.name ?? c.snapshot!.projection.kind}',
                    _state(c.snapshot!.projection, l),
                  ),
                if (c.commandReceipt != null)
                  _message(
                    'core-ha-command-${c.commandReceipt!.dispatchState.name}',
                    _commandState(c.commandReceipt!, l),
                  ),
                if (c.canRecoverCommand)
                  button(
                    'core-ha-command-recover',
                    l.coreHaCommandRecover,
                    () => unawaited(c.recoverCommand(isCurrent: ownerCurrent)),
                  ),
                if (c.snapshot?.projection.commandAvailable == true) ...[
                  Text(l.coreHaCommandReady),
                  button(
                    'core-ha-command-on',
                    l.coreHaTurnOn,
                    c.canCommand &&
                            c.snapshot!.projection.switchState != CoreHaSwitchState.on
                        ? () => unawaited(
                            c.command(
                              CoreHaCommandAction.turnOn,
                              isCurrent: ownerCurrent,
                            ),
                          )
                        : null,
                    selected:
                        c.snapshot!.projection.switchState == CoreHaSwitchState.on,
                  ),
                  button(
                    'core-ha-command-off',
                    l.coreHaTurnOff,
                    c.canCommand &&
                            c.snapshot!.projection.switchState !=
                                CoreHaSwitchState.off
                        ? () => unawaited(
                            c.command(
                              CoreHaCommandAction.turnOff,
                              isCurrent: ownerCurrent,
                            ),
                          )
                        : null,
                    selected:
                        c.snapshot!.projection.switchState == CoreHaSwitchState.off,
                  ),
                ] else if (c.snapshot != null)
                  Text(l.coreHaReadOnly),
              ] else if (c.fresh && c.loaded) ...[
                if (preview != null)
                  SettingsSection(
                    header: Semantics(
                      header: true,
                      child: Text(l.coreHaPreviewDetails),
                    ),
                    children: [
                      Padding(
                        key: const ValueKey('core-ha-preview-details'),
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(record!.label),
                            Text(service?.name ?? l.coreHaService),
                            Text(preview.binding.entityId),
                            Text(_state(preview.projection, l)),
                            const SizedBox(height: 12),
                            Text(l.coreHaPreviewDescription),
                            button(
                              'core-ha-cancel',
                              l.commonCancel,
                              c.canConfirm
                                  ? () => unawaited(
                                      c.cancel(
                                        preview,
                                        isCurrent: ownerCurrent,
                                      ),
                                    )
                                  : null,
                            ),
                            button(
                              'core-ha-confirm',
                              l.coreHaConfirm,
                              c.canConfirm
                                  ? () => unawaited(
                                      c.confirm(
                                        preview,
                                        isCurrent: ownerCurrent,
                                      ),
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                else ...[
                  if (c.binding != null)
                    SettingsSection(
                      header: Semantics(
                        header: true,
                        child: Text(l.coreHaExisting),
                      ),
                      children: [
                        Padding(
                          key: const ValueKey('core-ha-existing'),
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                c.services
                                        .where(
                                          (s) => s.id == c.binding!.serviceId,
                                        )
                                        .firstOrNull
                                        ?.name ??
                                    l.coreHaService,
                              ),
                              Text(c.binding!.entityId),
                            ],
                          ),
                        ),
                      ],
                    ),
                  SettingsSection(
                    header: Semantics(
                      header: true,
                      child: Text(l.coreHaService),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          c.services.isEmpty
                              ? l.coreHaNoServices
                              : l.coreHaChoose,
                        ),
                      ),
                      for (final value in c.services)
                        button(
                          'core-ha-service-${value.id}',
                          value.name,
                          c.canPreview
                              ? () => setState(() {
                                  _generation++;
                                  _service = value;
                                })
                              : null,
                          selected: identical(value, service),
                        ),
                    ],
                  ),
                  if (c.services.isNotEmpty)
                    SettingsSection(
                      header: Semantics(
                        header: true,
                        child: Text(l.coreHaEntity),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Semantics(
                                label: l.coreHaEntity,
                                child: CupertinoTextField(
                                  key: const ValueKey('core-ha-entity'),
                                  controller: _entity,
                                  enabled: c.canPreview,
                                  placeholder: 'switch.reading_lamp',
                                  maxLength: 128,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  textInputAction: TextInputAction.done,
                                  padding: const EdgeInsets.all(14),
                                  onChanged: (_) {
                                    if (ownerCurrent() && epoch == c.epoch) {
                                      setState(() {
                                        _generation++;
                                        _invalidEntity = false;
                                      });
                                    }
                                  },
                                ),
                              ),
                              if (_invalidEntity)
                                _message(
                                  'core-ha-invalid-entity',
                                  l.coreHaInvalidEntity,
                                ),
                              button(
                                'core-ha-preview',
                                l.coreHaPreview,
                                c.canPreview && service != null
                                    ? () {
                                        if (!coreHaEntityId(_entity.text)) {
                                          setState(() => _invalidEntity = true);
                                          return;
                                        }
                                        FocusManager.instance.primaryFocus
                                            ?.unfocus();
                                        unawaited(
                                          c.prepare(
                                            service,
                                            _entity.text,
                                            isCurrent: ownerCurrent,
                                          ),
                                        );
                                      }
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ],
            ]),
          ],
        );
      },
    );
  }
}
