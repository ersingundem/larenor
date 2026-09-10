import 'package:flutter/cupertino.dart';

import '../../server/data/larenor_server_api.dart';
import 'proxmox_power_api.dart';
import 'proxmox_power_controller.dart';
import 'proxmox_power_models.dart';

final class CoreProxmoxPowerPanel extends StatefulWidget {
  const CoreProxmoxPowerPanel({
    super.key,
    required this.api,
    required this.accessToken,
    required this.target,
    required this.isAdmin,
    required this.canWrite,
    required this.current,
  });

  final LarenorServerApi api;
  final String accessToken;
  final ProxmoxPowerTarget target;
  final bool isAdmin, canWrite;
  final bool Function() current;

  @override
  State<CoreProxmoxPowerPanel> createState() => _CoreProxmoxPowerPanelState();
}

final class _CoreProxmoxPowerPanelState extends State<CoreProxmoxPowerPanel> {
  late ProxmoxPowerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _create();
  }

  ProxmoxPowerController _create() => ProxmoxPowerController(
    gateway: CoreProxmoxPowerApi(widget.api, widget.accessToken),
    target: widget.target,
    current: widget.current,
  );

  @override
  void didUpdateWidget(CoreProxmoxPowerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.accessToken != widget.accessToken ||
        oldWidget.target != widget.target ||
        oldWidget.current != widget.current) {
      _controller.dispose();
      _controller = _create();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProxmoxPowerPanel(
    controller: _controller,
    isAdmin: widget.isAdmin,
    canWrite: widget.canWrite,
  );
}

/// Production entry used by the PIN-protected Core resource surface.
///
/// The command route is disabled until Core has supplied every exact revision
/// in [target]. The Client never guesses a guest or status revision from the
/// read-only Proxmox summary.
final class ProxmoxPowerEntry extends StatelessWidget {
  const ProxmoxPowerEntry({
    super.key,
    required this.isAdmin,
    required this.canWrite,
    required this.target,
    required this.current,
    required this.onOpen,
  });

  final bool isAdmin;
  final bool canWrite;
  final ProxmoxPowerTarget? target;
  final bool Function() current;
  final ValueChanged<ProxmoxPowerTarget> onOpen;

  @override
  Widget build(BuildContext context) {
    if (!isAdmin) return const SizedBox.shrink();
    final tr = Localizations.localeOf(context).languageCode == 'tr';
    final selected = target;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CupertinoButton.tinted(
          key: const ValueKey('core-proxmox-power-open'),
          minimumSize: const Size.fromHeight(48),
          onPressed: selected == null || !canWrite
              ? null
              : () {
                  if (current()) onOpen(selected);
                },
          child: Text(tr ? 'Güç denetimlerini aç' : 'Open power controls'),
        ),
        if (selected == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                tr
                    ? 'Kesin konuk durumu gereklidir.'
                    : 'Exact guest status is required.',
              ),
            ),
          ),
      ],
    );
  }
}

final class ProxmoxPowerPanel extends StatefulWidget {
  const ProxmoxPowerPanel({
    super.key,
    required this.controller,
    required this.isAdmin,
    required this.canWrite,
  });
  final ProxmoxPowerController controller;
  final bool isAdmin, canWrite;

  @override
  State<ProxmoxPowerPanel> createState() => _ProxmoxPowerPanelState();
}

final class _ProxmoxPowerPanelState extends State<ProxmoxPowerPanel>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(ProxmoxPowerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    if (!widget.isAdmin || !widget.canWrite) widget.controller.invalidate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) widget.controller.invalidate();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isAdmin) return const SizedBox.shrink();
    final tr = Localizations.localeOf(context).languageCode == 'tr';
    final labels = _Labels(tr);
    final controller = widget.controller;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Semantics(
              container: true,
              label: labels.title,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    labels.title,
                    style: CupertinoTheme.of(context)
                        .textTheme
                        .navLargeTitleTextStyle,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final action in controller.target.allowedActions)
                        Semantics(
                          button: true,
                          enabled:
                              widget.canWrite &&
                              controller.phase == ProxmoxPowerPhase.idle,
                          label: labels.action(action),
                          child: CupertinoButton.tinted(
                            minimumSize: const Size(120, 48),
                            onPressed:
                                widget.canWrite &&
                                    controller.phase == ProxmoxPowerPhase.idle
                                ? () => controller.preview(action)
                                : null,
                            child: Text(labels.action(action)),
                          ),
                        ),
                    ],
                  ),
                  if (controller.phase == ProxmoxPowerPhase.ready) ...[
                    const SizedBox(height: 24),
                    Semantics(liveRegion: true, child: Text(labels.review)),
                    if (controller.previewValue?.requiresSecondConfirmation ==
                        true)
                      Semantics(
                        label: labels.second,
                        button: true,
                        checked: controller.highRiskConfirmed,
                        excludeSemantics: true,
                        child: CupertinoButton(
                          minimumSize: const Size.fromHeight(48),
                          onPressed: () => controller.setHighRiskConfirmed(
                            !controller.highRiskConfirmed,
                          ),
                          child: Text(labels.second),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        CupertinoButton.filled(
                          minimumSize: const Size(160, 48),
                          onPressed: controller.canConfirm
                              ? controller.confirm
                              : null,
                          child: Text(labels.confirm),
                        ),
                        CupertinoButton(
                          minimumSize: const Size(120, 48),
                          onPressed: controller.cancel,
                          child: Text(labels.cancel),
                        ),
                      ],
                    ),
                  ],
                  if ({
                    ProxmoxPowerPhase.succeeded,
                    ProxmoxPowerPhase.failed,
                    ProxmoxPowerPhase.cancelled,
                    ProxmoxPowerPhase.unknown,
                  }.contains(controller.phase)) ...[
                    const SizedBox(height: 24),
                    Semantics(
                      liveRegion: true,
                      child: Text(labels.result(controller.phase)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _Labels {
  const _Labels(this.tr);
  final bool tr;
  String get title => tr ? 'Güç denetimleri' : 'Power controls';
  String get review => tr
      ? 'Komutu ve hedef durumu gözden geçir'
      : 'Review the command and expected state';
  String get second => tr ? 'İkinci onayı ver' : 'Give second confirmation';
  String get confirm => tr ? 'Açıkça onayla' : 'Explicitly confirm';
  String get cancel => tr ? 'İptal et' : 'Cancel';
  String action(ProxmoxPowerAction value) => switch (value) {
    ProxmoxPowerAction.start => tr ? 'Başlat' : 'Start',
    ProxmoxPowerAction.shutdown => tr ? 'Düzenli kapat' : 'Shut down',
    ProxmoxPowerAction.stop => tr ? 'Zorla durdur' : 'Stop',
    ProxmoxPowerAction.reboot => tr ? 'Yeniden başlat' : 'Reboot',
    ProxmoxPowerAction.reset => tr ? 'Zorla sıfırla' : 'Reset',
    ProxmoxPowerAction.suspend => tr ? 'Askıya al' : 'Suspend',
    ProxmoxPowerAction.resume => tr ? 'Sürdür' : 'Resume',
  };
  String result(ProxmoxPowerPhase phase) => switch (phase) {
    ProxmoxPowerPhase.succeeded => tr ? 'Komut doğrulandı' : 'Command verified',
    ProxmoxPowerPhase.cancelled =>
      tr ? 'Komut iptal edildi' : 'Command cancelled',
    ProxmoxPowerPhase.failed => tr ? 'Komut başarısız' : 'Command failed',
    _ =>
      tr ? 'Sonuç belirsiz; durumu yenile' : 'Outcome unknown; refresh status',
  };
}
