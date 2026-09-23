import 'package:flutter/cupertino.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../data/legacy_jellyfin_track_preferences_controller.dart';

final class LegacyJellyfinTrackPreferencesMigrationCard
    extends StatelessWidget {
  const LegacyJellyfinTrackPreferencesMigrationCard({
    super.key,
    required this.controller,
  });

  final LegacyJellyfinTrackPreferencesMigrationController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final state = controller.state;
      if (!const {
        LegacyJellyfinTrackPreferencesMigrationPhase.ready,
        LegacyJellyfinTrackPreferencesMigrationPhase.applying,
        LegacyJellyfinTrackPreferencesMigrationPhase.failed,
      }.contains(state.phase)) {
        return const SizedBox.shrink();
      }
      final l10n = AppLocalizations.of(context);
      final applying =
          state.phase == LegacyJellyfinTrackPreferencesMigrationPhase.applying;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: CupertinoPopupSurface(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Semantics(
                container: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        l10n.jellyfinLegacyTrackPreferencesTitle,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(l10n.jellyfinLegacyTrackPreferencesBody),
                    const SizedBox(height: 12),
                    if (state.audioLanguage case final String audio)
                      Text(
                        l10n.jellyfinLegacyTrackPreferencesAudio(
                          audio.toUpperCase(),
                        ),
                      ),
                    if (state.subtitleLanguage case final String subtitle)
                      Text(
                        l10n.jellyfinLegacyTrackPreferencesSubtitle(
                          subtitle == 'off'
                              ? l10n.jellyfinLegacyTrackPreferencesOff
                              : subtitle.toUpperCase(),
                        ),
                      ),
                    if (state.phase ==
                        LegacyJellyfinTrackPreferencesMigrationPhase
                            .failed) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          l10n.jellyfinLegacyTrackPreferencesFailed,
                          style: const TextStyle(
                            color: CupertinoColors.systemRed,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        Semantics(
                          key: const ValueKey(
                            'legacy-track-preferences-cancel',
                          ),
                          button: true,
                          enabled: !applying,
                          label: l10n.jellyfinLegacyTrackPreferencesCancel,
                          excludeSemantics: true,
                          child: CupertinoButton(
                            minimumSize: const Size(160, 48),
                            onPressed: applying ? null : controller.cancel,
                            child: Text(
                              l10n.jellyfinLegacyTrackPreferencesCancel,
                            ),
                          ),
                        ),
                        Semantics(
                          key: const ValueKey(
                            'legacy-track-preferences-confirm',
                          ),
                          button: true,
                          enabled: !applying,
                          label: applying
                              ? l10n.jellyfinLegacyTrackPreferencesApplying
                              : l10n.jellyfinLegacyTrackPreferencesConfirm,
                          excludeSemantics: true,
                          child: CupertinoButton.filled(
                            minimumSize: const Size(200, 48),
                            onPressed: applying ? null : controller.confirm,
                            child: applying
                                ? const CupertinoActivityIndicator()
                                : Text(
                                    l10n.jellyfinLegacyTrackPreferencesConfirm,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
