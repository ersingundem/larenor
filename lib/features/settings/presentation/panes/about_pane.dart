import 'package:flutter/cupertino.dart';

import '../../../../shared/widgets/settings_section.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/larenor_brand.dart';
import '../../../../shared/theme/typography.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../../legal/presentation/legal_screen.dart';
import 'settings_nav_row.dart';

class AboutPane extends ConsumerWidget {
  const AboutPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

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
          children: [
            CupertinoListTile(
              title: Text(l10n.legalTitle),
              trailing: const CupertinoListTileChevron(),
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(builder: (_) => const LegalScreen()),
              ),
            ),
            CupertinoListTile(
              title: Center(
                child: Text(
                  l10n.commonSignOut,
                  style: TextStyle(
                    color: CupertinoColors.systemRed.resolveFrom(context),
                  ),
                ),
              ),
              onTap: () async {
                await ref.read(connectionConfigProvider.notifier).signOut();
                if (context.mounted) context.go('/');
              },
            ),
          ],
        ),
      ],
    );
  }
}
