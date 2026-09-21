import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../data/camera_profile_controller.dart';
import '../domain/camera_profile_models.dart';

class CameraProfileScreen extends StatefulWidget {
  const CameraProfileScreen({super.key, required this.controller});
  final CameraProfileController controller;

  @override
  State<CameraProfileScreen> createState() => _CameraProfileScreenState();
}

class _CameraProfileScreenState extends State<CameraProfileScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.load();
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant CameraProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_changed);
    widget.controller.addListener(_changed);
    widget.controller.load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.setInteractive(false);
    super.dispose();
  }

  String _setting(AppLocalizations l10n, CameraSettingValue value) =>
      switch (value) {
        CameraSettingValue.enabled => l10n.cameraProfileEnabled,
        CameraSettingValue.paused => l10n.cameraProfilePaused,
        CameraSettingValue.disabled => l10n.cameraProfileDisabled,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;
    final snapshot = controller.snapshot;
    return ServiceRootScaffold(
      title: l10n.cameraProfileTitle,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Text(l10n.cameraProfileStatus),
            footer: Text(l10n.cameraProfilePrivacyBoundary),
            children: [
              _Status(controller: controller),
              if (snapshot != null && snapshot.hasUnsupported)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l10n.cameraProfileUnsupported),
                  ),
                ),
              SettingsActionTile(
                buttonKey: const ValueKey('camera-profile-apply'),
                leading: const Icon(CupertinoIcons.checkmark_shield),
                title: Text(l10n.cameraProfileApply),
                onTap: controller.canApply ? controller.apply : null,
              ),
            ],
          ),
        ),
        if (snapshot != null && snapshot.cameras.isEmpty)
          SliverToBoxAdapter(
            child: Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.cameraProfileEmpty),
              ),
            ),
          )
        else if (snapshot != null)
          SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 900 ? 2 : 1;
                final width =
                    (constraints.maxWidth - 16 * (columns + 1)) / columns;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      for (final camera in snapshot.cameras)
                        SizedBox(
                          width: width,
                          child: _CameraCard(
                            camera: camera,
                            result: controller.receipt?.results
                                .where((item) => item.cameraId == camera.id)
                                .firstOrNull,
                            setting: (value) => _setting(l10n, value),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.controller});
  final CameraProfileController controller;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = switch (controller.state) {
      CameraProfileViewState.idle ||
      CameraProfileViewState.loading ||
      CameraProfileViewState.applying => l10n.cameraProfileLoading,
      CameraProfileViewState.ready => l10n.cameraProfileStatus,
      CameraProfileViewState.verified => l10n.cameraProfileVerified,
      CameraProfileViewState.partial => l10n.cameraProfilePartial,
      CameraProfileViewState.failed => l10n.cameraProfileFailed,
      CameraProfileViewState.stale => l10n.cameraProfileStale,
    };
    return Semantics(
      liveRegion: true,
      label: text,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              if (controller.state == CameraProfileViewState.loading ||
                  controller.state == CameraProfileViewState.applying) ...[
                const CupertinoActivityIndicator(),
                const SizedBox(width: 12),
              ],
              Expanded(child: Text(text)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraCard extends StatelessWidget {
  const _CameraCard({
    required this.camera,
    required this.result,
    required this.setting,
  });
  final CameraProfileCamera camera;
  final CameraApplyResult? result;
  final String Function(CameraSettingValue) setting;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final resultText = switch (result?.state) {
      CameraApplyState.applied => l10n.cameraProfileVerified,
      CameraApplyState.skipped => l10n.cameraProfileCurrent,
      CameraApplyState.failed ||
      CameraApplyState.unknown => l10n.cameraProfilePartial,
      null => null,
    };
    return Semantics(
      container: true,
      label: camera.name,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                camera.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              _row(
                l10n.cameraProfileRecording,
                setting(camera.currentRecording),
                setting(camera.desiredRecording),
                camera.recordingSupported,
                l10n,
              ),
              const SizedBox(height: 10),
              _row(
                l10n.cameraProfileDetection,
                setting(camera.currentDetection),
                setting(camera.desiredDetection),
                camera.detectionSupported,
                l10n,
              ),
              if (resultText != null) ...[
                const SizedBox(height: 12),
                Text(resultText),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(
    String label,
    String current,
    String desired,
    bool supported,
    AppLocalizations l10n,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '$label · ${supported ? l10n.cameraProfileProviderSupported : l10n.cameraProfileProviderUnsupported}',
      ),
      Text(
        '${l10n.cameraProfileCurrent}: $current · ${l10n.cameraProfileDesired}: $desired',
      ),
    ],
  );
}
