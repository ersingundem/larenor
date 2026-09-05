import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/window/window_policy_models.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/settings_section.dart';
import '../providers/window_profile_provider.dart';
import 'panes/settings_nav_row.dart';

class WindowPanelScreen extends ConsumerStatefulWidget {
  const WindowPanelScreen({super.key});
  @override
  ConsumerState<WindowPanelScreen> createState() => _WindowPanelScreenState();
}

class _WindowPanelScreenState extends ConsumerState<WindowPanelScreen> {
  bool _saving = false;
  bool _saveFailed = false;

  bool get _current =>
      mounted &&
      ModalRoute.of(context)?.isCurrent == true &&
      AppInteractionScope.maybeRead(context)?.active != false &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  Future<void> _setProfile(WindowProfile profile) async {
    if (!_current || _saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      await ref.read(windowProfileProvider.notifier).set(profile);
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final preference = ref.watch(windowProfileProvider);
    final reading = ref.watch(windowPolicySnapshotProvider);
    final snapshot = reading.isLoading || reading.hasError
        ? null
        : reading.value;
    final selected = preference.isLoading || preference.hasError
        ? null
        : preference.value;
    String flag(bool? value) => value == null
        ? l10n.commonUnknown
        : value
        ? l10n.commonYes
        : l10n.commonNo;
    return SettingsPaneScaffold(
      title: l10n.windowTitle,
      children: [
        SettingsSection(
          header: Text(l10n.windowProfile),
          children: [
            for (final profile in WindowProfile.values)
              Semantics(
                selected: selected == profile,
                child: CupertinoButton(
                  padding: const EdgeInsets.all(16),
                  onPressed:
                      _saving ||
                          selected == null ||
                          (profile == WindowProfile.panel &&
                              snapshot?.supported != true)
                      ? null
                      : () => _setProfile(profile),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              profile == WindowProfile.adaptive
                                  ? l10n.windowAdaptive
                                  : l10n.windowPanel,
                              style: AppText.headline.copyWith(
                                color: CupertinoColors.label.resolveFrom(
                                  context,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              profile == WindowProfile.adaptive
                                  ? l10n.windowAdaptiveHint
                                  : l10n.windowPanelHint,
                              style: AppText.footnote.copyWith(
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        selected == profile
                            ? CupertinoIcons.check_mark_circled_solid
                            : CupertinoIcons.circle,
                        color: CupertinoTheme.of(context).primaryColor,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (_saving)
          const Padding(
            padding: EdgeInsets.all(16),
            child: CupertinoActivityIndicator(),
          ),
        if (_saveFailed || preference.hasError)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(l10n.windowSaveFailed),
          ),
        SettingsSection(
          header: Text(l10n.windowStatus),
          children: [
            if (reading.isLoading)
              const Padding(
                padding: EdgeInsets.all(20),
                child: CupertinoActivityIndicator(),
              )
            else ...[
              _WindowValue(
                label: _mode(l10n, snapshot),
                value: _reason(l10n, snapshot),
              ),
              _WindowValue(
                label: l10n.windowStatusBar,
                value: flag(snapshot?.statusBarVisible),
              ),
              _WindowValue(
                label: l10n.windowNavigationBar,
                value: flag(snapshot?.navigationBarVisible),
              ),
              _WindowValue(
                label: l10n.windowMultiWindow,
                value: flag(
                  snapshot?.supported == true ? snapshot?.isMultiWindow : null,
                ),
              ),
              _WindowValue(
                label: l10n.windowExternalDisplay,
                value: flag(
                  snapshot?.supported == true
                      ? snapshot?.isExternalDisplay
                      : null,
                ),
              ),
            ],
            CupertinoButton(
              onPressed: reading.isLoading
                  ? null
                  : () {
                      if (_current) {
                        ref.invalidate(windowPolicySnapshotProvider);
                      }
                    },
              child: Text(l10n.commonRefresh),
            ),
          ],
        ),
        SettingsSection(
          header: Text(l10n.windowKiosk),
          footer: Text(l10n.windowKioskHint),
          children: [
            _WindowValue(
              label: switch (snapshot?.lockTaskState) {
                WindowLockTaskState.none => l10n.windowKioskNone,
                WindowLockTaskState.pinned => l10n.windowKioskPinned,
                WindowLockTaskState.locked => l10n.windowKioskLocked,
                _ => l10n.commonUnknown,
              },
            ),
            _WindowValue(
              label: l10n.windowKioskPermitted,
              value: flag(snapshot?.lockTaskPermitted),
            ),
          ],
        ),
        SettingsSection(
          header: Text(l10n.windowShortcuts),
          children: [_WindowValue(label: l10n.windowShortcutsHint)],
        ),
      ],
    );
  }
}

String _mode(AppLocalizations l10n, WindowPolicySnapshot? snapshot) {
  if (snapshot == null) return l10n.windowUnknown;
  if (!snapshot.supported) return l10n.windowUnsupported;
  return switch (snapshot.effectiveMode) {
    WindowEffectiveMode.adaptive => l10n.windowAdaptive,
    WindowEffectiveMode.panelRequested => l10n.windowPanelRequested,
    WindowEffectiveMode.restricted => l10n.windowRestricted,
    WindowEffectiveMode.unknown => l10n.windowUnknown,
  };
}

String? _reason(AppLocalizations l10n, WindowPolicySnapshot? snapshot) =>
    switch (snapshot?.reason) {
      WindowRestrictionReason.notForeground ||
      WindowRestrictionReason.noFocus => l10n.windowReasonFocus,
      WindowRestrictionReason.multiWindow ||
      WindowRestrictionReason.pictureInPicture ||
      WindowRestrictionReason.captionBar ||
      WindowRestrictionReason.desktopMode ||
      WindowRestrictionReason.externalDisplay => l10n.windowReasonDesktop,
      WindowRestrictionReason.keyboard => l10n.windowReasonKeyboard,
      _ => null,
    };

class _WindowValue extends StatelessWidget {
  const _WindowValue({required this.label, this.value});
  final String label;
  final String? value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.body),
          if (value != null) ...[
            const SizedBox(height: 6),
            Text(
              value!,
              style: AppText.subhead.copyWith(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
