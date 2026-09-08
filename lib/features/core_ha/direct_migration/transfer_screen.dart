import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../home_resources/domain/home_resource_models.dart';
import '../domain/core_ha_models.dart';
import '../presentation/core_ha_widgets.dart';
import 'transfer_controller.dart';
import 'transfer_providers.dart';
import 'transfer_route.dart';

class CoreHaTransferScreen extends StatelessWidget {
  const CoreHaTransferScreen({
    super.key,
    required this.gateCurrent,
    this.onExit,
  });
  final bool Function() gateCurrent;
  final VoidCallback? onExit;
  @override
  Widget build(BuildContext context) => CoreHaTransferRoute(
    title: AppLocalizations.of(context).coreHaTransferTitle,
    gateCurrent: gateCurrent,
    onExit: onExit,
    builder: (owner) => _TransferPage(owner: owner, onExit: onExit),
  );
}

class _TransferPage extends ConsumerStatefulWidget {
  const _TransferPage({required this.owner, this.onExit});
  final CoreHaTransferOwner owner;
  final VoidCallback? onExit;
  @override
  ConsumerState<_TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends ConsumerState<_TransferPage> {
  CoreHaTransferController? _controller;
  HomeResourceRecord? _target;
  String? _entity;
  int _selection = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.owner.isCurrent) _controller?.load();
    });
  }

  bool _current(int selection) =>
      mounted &&
      _selection == selection &&
      widget.owner.isCurrent &&
      ModalRoute.of(context)?.isCurrent == true &&
      TickerMode.valuesOf(context).enabled;
  @override
  Widget build(BuildContext context) {
    final c = ref.watch(coreHaTransferControllerProvider(widget.owner));
    _controller = c;
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (_, _) {
        final selection = _selection, stamp = c.epoch, preview = c.preview;
        bool current() => _current(selection) && c.epoch == stamp && c.fresh;
        Widget action(
          String key,
          String label,
          VoidCallback? onPressed, {
          bool? selected,
        }) => CoreHaButton(
          key: ValueKey(key),
          label: label,
          selected: selected,
          isCurrent: current,
          onPressed: onPressed == null
              ? null
              : () {
                  if (current()) onPressed();
                },
        );
        Widget heading(String text) => Semantics(
          container: true,
          header: true,
          child: Text(
            text,
            style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
          ),
        );
        return CoreHaPage(
          key: const ValueKey('core-ha-transfer'),
          title: l.coreHaTransferTitle,
          backKey: 'core-ha-transfer-back',
          onBack: current()
              ? () {
                  if (current()) {
                    if (widget.onExit != null) {
                      widget.onExit!();
                    } else {
                      Navigator.of(context).maybePop();
                    }
                  }
                }
              : null,
          slivers: [
            coreHaBlock([
              Text(l.coreHaTransferHint),
              const SizedBox(height: 12),
              Text(l.coreHaTransferExcluded),
              if (!c.fresh)
                Text(
                  l.coreHaTransferRequired,
                  key: const ValueKey('core-ha-transfer-required'),
                ),
              if (c.busy)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    l.coreHaLoading,
                    key: const ValueKey('core-ha-transfer-loading'),
                  ),
                ),
              if (c.failure != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _failure(l, c.failure!),
                    key: const ValueKey('core-ha-transfer-error'),
                  ),
                ),
              if (c.uncertain) ...[
                Text(
                  l.coreHaTransferUncertain,
                  key: const ValueKey('core-ha-transfer-uncertain'),
                ),
                action(
                  'core-ha-transfer-recover',
                  l.coreHaTransferRecover,
                  c.canRecover
                      ? () => c.recover(isCurrent: () => _current(selection))
                      : null,
                ),
              ],
              if (c.receipt != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    l.coreHaTransferSuccess,
                    key: const ValueKey('core-ha-transfer-success'),
                  ),
                ),
              if (c.receipt == null && !c.uncertain && preview == null) ...[
                action(
                  'core-ha-transfer-refresh',
                  l.commonRefresh,
                  c.canLoad
                      ? () {
                          setState(() {
                            _selection++;
                            _target = null;
                            _entity = null;
                          });
                          c.load();
                        }
                      : null,
                ),
                if (c.loaded && (c.entities.isEmpty || c.items.isEmpty))
                  Text(
                    l.coreHaTransferEmpty,
                    key: const ValueKey('core-ha-transfer-empty'),
                  ),
                if (c.loaded && c.entities.isNotEmpty) ...[
                  heading(l.coreHaTransferSource),
                  SettingsSection(
                    children: [
                      for (final entity in c.entities)
                        action(
                          'core-ha-transfer-entity-$entity',
                          entity,
                          c.canPrepare
                              ? () {
                                  setState(() {
                                    _selection++;
                                    _entity = entity;
                                  });
                                }
                              : null,
                          selected: entity == _entity,
                        ),
                    ],
                  ),
                  if(c.items.isNotEmpty) ...[
                  heading(l.coreHaTransferTarget),
                  SettingsSection(
                    children: [
                      for (final target in c.items)
                        action(
                          'core-ha-transfer-target-${target.id}',
                          target.label,
                          c.canPrepare
                              ? () {
                                  setState(() {
                                    _selection++;
                                    _target = target;
                                  });
                                }
                              : null,
                          selected: identical(target, _target),
                        ),
                    ],
                  ),
                  ],
                  if (c.nextAfter != null)
                    action(
                      'core-ha-transfer-more',
                      l.homeResourcesLoadMore,
                      c.canLoad ? () => c.load(more: true) : null,
                    ),
                  action(
                    'core-ha-transfer-preview',
                    l.coreHaTransferPreview,
                    c.canPrepare && _entity != null && _target != null
                        ? () => c.prepare(
                            _target!,
                            _entity!,
                            isCurrent: () => _current(selection),
                          )
                        : null,
                  ),
                ],
              ],
              if (preview != null) ...[
                heading(l.coreHaTransferReview),
                Text(preview.commit.binding.target.label),
                Text(preview.commit.binding.entityId),
                Text(preview.commit.service.name),
                Text(switch (preview.projection.state) {
                  CoreHaSwitchState.on => l.coreHaStateOn,
                  CoreHaSwitchState.off => l.coreHaStateOff,
                  CoreHaSwitchState.unavailable => l.coreHaUnavailable,
                }),
                Text(l.coreHaPreviewDescription),
                action(
                  'core-ha-transfer-cancel',
                  l.commonCancel,
                  c.canConfirm
                      ? () => c.cancel(
                          preview,
                          isCurrent: () => _current(selection),
                        )
                      : null,
                ),
                action(
                  'core-ha-transfer-confirm',
                  l.coreHaTransferConfirm,
                  c.canConfirm
                      ? () => c.confirm(
                          preview,
                          isCurrent: () => _current(selection),
                        )
                      : null,
                ),
              ],
            ]),
          ],
        );
      },
    );
  }
}

String _failure(AppLocalizations l, String code) => switch (code) {
  'pending_mutation' ||
  'invalid_record' ||
  'storage_failed' => l.coreHaTransferCredentials,
  'ha_migration_changed' ||
  'ha_binding_changed' ||
  'revision_conflict' => l.coreHaChanged,
  'ha_migration_preview_invalid' => l.coreHaPreviewExpired,
  'forbidden' || 'not_found' => l.coreHaPermission,
  'ha_upstream_unauthorized' => l.coreHaUpstreamAuth,
  'ha_upstream_unavailable' ||
  'connection_failed' ||
  'timeout' => l.coreHaOffline,
  'ha_projection_unsupported' => l.coreHaUnsupported,
  _ => l.coreHaError,
};
