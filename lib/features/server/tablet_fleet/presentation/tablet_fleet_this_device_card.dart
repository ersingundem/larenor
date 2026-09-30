import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/settings_action_tile.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../runtime/tablet_fleet_device_runtime.dart';
import '../runtime/tablet_fleet_device_runtime_scope.dart';

final class TabletFleetThisDeviceCard extends ConsumerStatefulWidget {
  const TabletFleetThisDeviceCard({
    required this.enabled,
    required this.current,
    super.key,
  });

  final bool enabled;
  final bool Function() current;

  @override
  ConsumerState<TabletFleetThisDeviceCard> createState() =>
      _TabletFleetThisDeviceCardState();
}

final class _TabletFleetThisDeviceCardState
    extends ConsumerState<TabletFleetThisDeviceCard> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _enroll(TabletFleetDeviceRuntime runtime) async {
    final value = _name.text.trim();
    if (!widget.current() || value.isEmpty) return;
    try {
      await runtime.enroll(value);
    } catch (_) {
      return;
    }
    if (mounted && widget.current()) _name.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final runtime = ref.watch(tabletFleetDeviceRuntimeProvider);
    final enrolled = runtime.record;
    final canAct = widget.enabled && !runtime.busy && widget.current();
    return AnimatedBuilder(
      animation: runtime,
      builder: (context, _) => SettingsSection(
        header: Text(l10n.serverTabletFleetThisDevice),
        footer: Text(
          enrolled == null
              ? l10n.serverTabletFleetEnrollHint
              : l10n.serverTabletFleetEnrollmentScope,
        ),
        children: [
          if (enrolled == null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: CupertinoTextField(
                key: const ValueKey('tablet-fleet-this-device-name'),
                controller: _name,
                enabled: canAct,
                maxLength: 80,
                placeholder: l10n.serverTabletFleetDeviceName,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(_enroll(runtime)),
              ),
            ),
            SettingsActionTile(
              buttonKey: const ValueKey('tablet-fleet-enroll-this-device'),
              leading: const Icon(CupertinoIcons.device_phone_portrait),
              title: Text(l10n.serverTabletFleetEnrollThisDevice),
              onTap: canAct ? () => _enroll(runtime) : null,
            ),
          ] else ...[
            CupertinoListTile(
              key: const ValueKey('tablet-fleet-this-device-status'),
              leading: const Icon(CupertinoIcons.checkmark_shield_fill),
              title: Text(enrolled.tablet.name),
              subtitle: Text(
                enrolled.tablet.mode.name == 'deviceOwner'
                    ? l10n.serverTabletFleetDeviceOwner
                    : l10n.serverTabletFleetStandard,
              ),
              additionalInfo: Text(
                l10n.serverTabletFleetProfileRevisions(
                  enrolled.tablet.appliedProfileRevision,
                  enrolled.tablet.desiredProfileRevision,
                ),
              ),
            ),
            SettingsActionTile(
              buttonKey: const ValueKey('tablet-fleet-revoke-this-device'),
              leading: const Icon(CupertinoIcons.xmark_circle),
              title: Text(l10n.serverTabletFleetStopThisDevice),
              onTap: canAct ? runtime.revoke : null,
            ),
          ],
          if (runtime.failure != null)
            CupertinoListTile(
              key: const ValueKey('tablet-fleet-this-device-failure'),
              title: Text(l10n.serverTabletFleetDeviceUnavailable),
            ),
        ],
      ),
    );
  }
}
