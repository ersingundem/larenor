import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../settings/presentation/panes/settings_nav_row.dart';
import '../domain/dual_display_session.dart';

abstract interface class DualDisplayTaskViewModel implements Listenable {
  bool get busy;
  String? get failure;
  DisplayTopology? get topology;
  DualDisplayState? get state;
  Future<void> refresh();
  Future<void> activate(DisplaySurface display, String routeId);
  Future<void> disconnect();
}

/// Tablet-first task manager for one primary and up to four external displays.
class DualDisplayTaskScreen extends StatelessWidget {
  const DualDisplayTaskScreen({super.key, required this.controller});

  final DualDisplayTaskViewModel controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SettingsPaneScaffold(
      title: l10n.dualDisplayTitle,
      children: [
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final topology = controller.topology;
            final state = controller.state;
            final active = state?.status == DualDisplayStatus.active;
            final external =
                topology?.surfaces
                    .where((surface) => surface.kind == DisplayKind.external)
                    .toList(growable: false) ??
                const <DisplaySurface>[];
            final status = controller.busy
                ? l10n.dualDisplayLoading
                : controller.failure != null
                ? l10n.dualDisplayUnavailable
                : active
                ? l10n.dualDisplayActive
                : external.isEmpty
                ? l10n.dualDisplayNoExternal
                : l10n.dualDisplayReady;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsSection(
                  header: Text(l10n.dualDisplayStatus),
                  footer: Text(l10n.dualDisplayPrivacyHint),
                  children: [
                    _DisplayValue(
                      key: const ValueKey('dual-display-status'),
                      label: status,
                      liveRegion: true,
                    ),
                    SettingsActionTile(
                      buttonKey: const ValueKey('dual-display-refresh'),
                      leading: const Icon(CupertinoIcons.refresh),
                      title: Text(l10n.commonRefresh),
                      onTap: controller.busy
                          ? null
                          : () => unawaited(controller.refresh()),
                    ),
                    if (active)
                      SettingsActionTile(
                        buttonKey: const ValueKey('dual-display-disconnect'),
                        leading: const Icon(CupertinoIcons.stop_circle),
                        title: Text(l10n.dualDisplayDisconnect),
                        onTap: controller.busy
                            ? null
                            : () => unawaited(controller.disconnect()),
                      ),
                  ],
                ),
                if (topology != null)
                  SettingsSection(
                    header: Text(l10n.dualDisplayScreens),
                    children: [
                      _DisplayValue(
                        key: ValueKey(
                          'dual-display-primary-${topology.primary.displayId}',
                        ),
                        label: l10n.dualDisplayPrimary,
                        detail: _dimensions(topology.primary),
                      ),
                      for (final display in external)
                        _DisplayValue(
                          key: ValueKey(
                            'dual-display-external-${display.displayId}',
                          ),
                          label: l10n.dualDisplayExternal,
                          detail: _dimensions(display),
                        ),
                    ],
                  ),
                for (final display in external)
                  SettingsSection(
                    header: Text(
                      '${l10n.dualDisplayExternal} ${display.displayId}',
                    ),
                    children: [
                      SettingsActionTile(
                        buttonKey: ValueKey(
                          'dual-display-dashboard-${display.displayId}',
                        ),
                        selected:
                            active &&
                            state?.secondaryDisplayId == display.displayId &&
                            state?.secondaryRouteId == 'dashboard.overview',
                        leading: const Icon(CupertinoIcons.square_grid_2x2),
                        title: Text(l10n.dualDisplayShowDashboard),
                        onTap: controller.busy
                            ? null
                            : () => unawaited(
                                controller.activate(
                                  display,
                                  'dashboard.overview',
                                ),
                              ),
                      ),
                      SettingsActionTile(
                        buttonKey: ValueKey(
                          'dual-display-media-${display.displayId}',
                        ),
                        selected:
                            active &&
                            state?.secondaryDisplayId == display.displayId &&
                            state?.secondaryRouteId == 'media.now-playing',
                        leading: const Icon(CupertinoIcons.play_rectangle),
                        title: Text(l10n.dualDisplayShowMedia),
                        onTap: controller.busy
                            ? null
                            : () => unawaited(
                                controller.activate(
                                  display,
                                  'media.now-playing',
                                ),
                              ),
                      ),
                    ],
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  static String _dimensions(DisplaySurface display) =>
      '${display.widthPixels} × ${display.heightPixels} · ${display.densityDpi} dpi';
}

class _DisplayValue extends StatelessWidget {
  const _DisplayValue({
    super.key,
    required this.label,
    this.detail,
    this.liveRegion = false,
  });

  final String label;
  final String? detail;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: liveRegion,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label),
            if (detail != null) ...[
              const SizedBox(height: 4),
              Text(
                detail!,
                style: TextStyle(
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
