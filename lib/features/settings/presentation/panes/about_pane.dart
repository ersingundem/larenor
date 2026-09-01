import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../auth/providers/auth_providers.dart';
import 'settings_nav_row.dart';

class AboutPane extends ConsumerWidget {
  const AboutPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    return SettingsPaneScaffold(
      title: l10n.settingsCategoryAbout,
      children: [
        CupertinoListSection.insetGrouped(
          children: [
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
