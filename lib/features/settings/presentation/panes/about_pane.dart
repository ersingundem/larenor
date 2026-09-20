import 'package:flutter/cupertino.dart';

import '../../../../core/app_interaction_scope.dart';
import '../../../../shared/widgets/settings_section.dart';
import '../../../../shared/widgets/settings_action_tile.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/larenor_brand.dart';
import '../../../../shared/theme/typography.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../legal/presentation/legal_screen.dart';
import 'settings_nav_row.dart';

class AboutPane extends ConsumerStatefulWidget {
  const AboutPane({super.key});

  @override
  ConsumerState<AboutPane> createState() => _AboutPaneState();
}

class _AboutPaneState extends ConsumerState<AboutPane> {
  bool _signingOut = false;

  bool _current(AppInteractionController? interaction, int? epoch) =>
      mounted &&
      ModalRoute.of(context)?.isCurrent == true &&
      TickerMode.valuesOf(context).enabled &&
      identical(interaction, AppInteractionScope.maybeRead(context)) &&
      interaction?.active != false &&
      interaction?.epoch == epoch;

  Future<void> _signOut(
    AppInteractionController? interaction,
    int? epoch,
  ) async {
    if (_signingOut || !_current(interaction, epoch)) return;
    setState(() => _signingOut = true);
    try {
      await ref.read(connectionConfigProvider.notifier).signOut();
      if (!mounted) return;
      if (_current(interaction, epoch)) context.go('/');
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Keep the auto-dispose notifier alive through a pending credential clear.
    ref.watch(connectionConfigProvider);
    final interaction = AppInteractionScope.maybeOf(context);
    final interactionEpoch = interaction?.epoch;

    return SettingsPaneScaffold(
      title: l10n.settingsCategoryAbout,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                children: [
                  const LarenorBrand(centered: true),
                  const SizedBox(height: 28),
                  Text(
                    l10n.aboutAppDescription,
                    textAlign: TextAlign.center,
                    style: AppText.body.copyWith(height: 1.5),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    l10n.aboutAppPrivacy,
                    textAlign: TextAlign.center,
                    style: AppText.footnote.copyWith(
                      height: 1.5,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SettingsSection(
          header: Semantics(
            key: const ValueKey('about-actions-header'),
            container: true,
            header: true,
            child: Text(l10n.settingsCategoryAbout),
          ),
          children: [
            SettingsActionTile(
              buttonKey: const ValueKey('about-legal-action'),
              title: Text(l10n.legalTitle),
              onTap: () {
                if (_current(interaction, interactionEpoch)) {
                  Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                      builder: (_) => const LegalScreen(),
                    ),
                  );
                }
              },
            ),
            SettingsActionTile(
              buttonKey: const ValueKey('about-sign-out-action'),
              title: Text(
                l10n.commonSignOut,
                style: TextStyle(
                  color: CupertinoColors.systemRed.resolveFrom(context),
                ),
              ),
              onTap: _signingOut
                  ? null
                  : () => _signOut(interaction, interactionEpoch),
            ),
          ],
        ),
      ],
    );
  }
}
