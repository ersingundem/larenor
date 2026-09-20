import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_interaction_scope.dart';
import '../../../core/window/window_policy_models.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../providers/window_profile_provider.dart';
import 'panes/settings_nav_row.dart';

class WindowPanelScreen extends ConsumerStatefulWidget {
  const WindowPanelScreen({super.key});
  @override
  ConsumerState<WindowPanelScreen> createState() => _WindowPanelScreenState();
}

class _WindowPanelScreenState extends ConsumerState<WindowPanelScreen>
    with WidgetsBindingObserver {
  bool _saving = false;
  bool _saveFailed = false;
  bool _foreground = true;
  bool _wasVisible = true;
  int _generation = 0;
  AppInteractionController? _interaction;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    if (_wasVisible && !visible) _expireInteraction();
    _wasVisible = visible;
    final interaction = AppInteractionScope.maybeOf(context);
    if (!identical(interaction, _interaction)) {
      _interaction?.removeListener(_interactionChanged);
      _interaction = interaction;
      _interaction?.addListener(_interactionChanged);
    }
  }

  void _interactionChanged() {
    if (_interaction?.active == false) _expireInteraction();
  }

  void _expireInteraction() {
    _generation++;
    _saving = false;
    _saveFailed = false;
  }

  bool get _current =>
      mounted &&
      _foreground &&
      ModalRoute.of(context)?.isCurrent == true &&
      _interaction?.active != false &&
      TickerMode.valuesOf(context).enabled;

  bool _operationCurrent(int generation) =>
      _current && generation == _generation;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground && !foreground) _expireInteraction();
    _foreground = foreground;
  }

  @override
  void dispose() {
    _generation++;
    _interaction?.removeListener(_interactionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _setProfile(WindowProfile profile, int generation) async {
    if (!_operationCurrent(generation) || _saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      await ref
          .read(windowProfileProvider.notifier)
          .set(profile, isCurrent: () => _operationCurrent(generation));
    } catch (_) {
      if (_operationCurrent(generation)) {
        setState(() => _saveFailed = true);
      }
    } finally {
      if (_operationCurrent(generation)) {
        setState(() => _saving = false);
      }
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
    final generation = _generation;
    String flag(bool? value) => value == null
        ? l10n.commonUnknown
        : value
        ? l10n.commonYes
        : l10n.commonNo;
    return SettingsPaneScaffold(
      title: l10n.windowTitle,
      children: [
        SettingsSection(
          header: Semantics(
            key: const ValueKey('window-profile-heading'),
            container: true,
            header: true,
            child: Text(l10n.windowProfile),
          ),
          children: [
            for (final profile in WindowProfile.values)
              SettingsActionTile(
                buttonKey: ValueKey('window-profile-${profile.name}'),
                selected: selected == profile,
                leading: Icon(
                  selected == profile
                      ? CupertinoIcons.check_mark_circled_solid
                      : CupertinoIcons.circle,
                ),
                title: Text(
                  profile == WindowProfile.adaptive
                      ? l10n.windowAdaptive
                      : l10n.windowPanel,
                ),
                additionalInfo: Text(
                  profile == WindowProfile.adaptive
                      ? l10n.windowAdaptiveHint
                      : l10n.windowPanelHint,
                ),
                onTap:
                    _saving ||
                        selected == null ||
                        (profile == WindowProfile.panel &&
                            snapshot?.supported != true)
                    ? null
                    : () => _setProfile(profile, generation),
              ),
          ],
        ),
        if (_saving)
          const Padding(
            padding: EdgeInsets.all(16),
            child: CupertinoActivityIndicator(),
          ),
        if (_saveFailed || preference.hasError)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(l10n.windowSaveFailed),
            ),
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
            SettingsActionTile(
              buttonKey: const ValueKey('window-status-refresh'),
              leading: const Icon(CupertinoIcons.refresh),
              title: Text(l10n.commonRefresh),
              onTap: reading.isLoading
                  ? null
                  : () {
                      if (_operationCurrent(generation)) {
                        ref.invalidate(windowPolicySnapshotProvider);
                      }
                    },
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
