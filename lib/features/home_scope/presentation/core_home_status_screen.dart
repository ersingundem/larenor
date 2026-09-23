import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app_interaction_scope.dart';
import '../../home_resources/presentation/core_home_resources.dart';
import '../../home_people/presentation/home_people_screen.dart';
import '../../../core/home_session_controller.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';

/// Core metadata and independent account recovery; no home adapters are mounted.
class CoreHomeStatusScreen extends ConsumerWidget {
  const CoreHomeStatusScreen({super.key});
  Widget _statusRow(Widget child) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Padding(
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: 16,
        vertical: 12,
      ),
      child: Align(alignment: AlignmentDirectional.centerStart, child: child),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(homeSessionControllerProvider)!;
    final l10n = AppLocalizations.of(context);
    final interaction = AppInteractionScope.maybeOf(context);
    final epoch = interaction?.epoch;
    bool current() =>
        context.mounted &&
        (interaction?.active ?? true) &&
        interaction?.epoch == epoch &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent == true;
    return ServiceRootScaffold(
      title: l10n.homeSourceCore,
      slivers: [
        SliverToBoxAdapter(
          child: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => SettingsSection(
              footer: Text(l10n.homeCoreUnavailable),
              children: [
                _statusRow(
                  Text(
                    controller.failure != null
                        ? l10n.homeSourceStorageError
                        : controller.busy
                        ? l10n.homeSourceLoading
                        : controller.account.context != null
                        ? l10n.homeCoreVerified
                        : l10n.homeCoreVerificationRequired,
                  ),
                ),
                if (controller.account.failure
                    case 'storage_failed' || 'logout_not_confirmed')
                  Semantics(
                    liveRegion: true,
                    child: _statusRow(
                      Text(
                        controller.account.failure == 'storage_failed'
                            ? l10n.serverFailureStorage
                            : l10n.serverLogoutUnconfirmed,
                        style: TextStyle(
                          color: CupertinoColors.systemRed.resolveFrom(context),
                        ),
                      ),
                    ),
                  ),
                SettingsActionTile(
                  key: const ValueKey('core-home-source-entry'),
                  buttonKey: const ValueKey('core-home-source-action'),
                  title: Text(l10n.homeSourceTitle),
                  onTap: controller.busy || !current()
                      ? null
                      : () {
                          if (current()) {
                            context.push('/settings/home-source');
                          }
                        },
                ),
              ],
            ),
          ),
        ),
        const SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          sliver: CoreHomeResources(),
        ),
        SliverToBoxAdapter(
          child: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => SettingsSection(
              children: [
                const HomePeopleEntry(),
                if (controller.failure == null && !controller.busy)
                  SettingsActionTile(
                    key: const ValueKey('core-home-manage-account-entry'),
                    buttonKey: const ValueKey(
                      'core-home-manage-account-action',
                    ),
                    title: Text(l10n.homeCoreManageAccount),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) context.push('/settings');
                          },
                  ),
                if (controller.account.context != null &&
                    controller.account.session?.user.canAdminister == true)
                  SettingsActionTile(
                    key: const ValueKey('core-home-music-entry'),
                    buttonKey: const ValueKey('core-home-music-action'),
                    title: Text(l10n.serverMusicManagerTitle),
                    additionalInfo: Text(l10n.serverMusicManagerIntro),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) context.push('/media/music');
                          },
                  ),
                if (controller.account.context != null &&
                    controller.account.session?.user.canAdminister == true)
                  SettingsActionTile(
                    key: const ValueKey('core-home-media-archive-entry'),
                    buttonKey: const ValueKey('core-home-media-archive-action'),
                    title: Text(l10n.mediaArchiveTitle),
                    additionalInfo: Text(l10n.mediaArchiveReadOnly),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) {
                              context.push('/media/archive-health');
                            }
                          },
                  ),
                if (controller.account.context != null)
                  SettingsActionTile(
                    key: const ValueKey('core-home-camera-search-entry'),
                    buttonKey: const ValueKey('core-home-camera-search-action'),
                    title: Text(l10n.cameraSearchTitle),
                    additionalInfo: Text(l10n.cameraSearchEntrySubtitle),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) {
                              context.push('/camera-search');
                            }
                          },
                  ),
                if (controller.account.context != null)
                  SettingsActionTile(
                    key: const ValueKey('core-home-epaper-entry'),
                    buttonKey: const ValueKey('core-home-epaper-action'),
                    title: Text(l10n.epaperTitle),
                    additionalInfo: Text(l10n.epaperEntrySubtitle),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) context.push('/epaper');
                          },
                  ),
                if (controller.account.context != null)
                  SettingsActionTile(
                    key: const ValueKey('core-home-room-presence-entry'),
                    buttonKey: const ValueKey('core-home-room-presence-action'),
                    title: Text(l10n.roomPresenceTitle),
                    additionalInfo: Text(l10n.roomPresenceEntrySubtitle),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) {
                              context.push('/room-presence');
                            }
                          },
                  ),
                if (controller.account.context != null)
                  SettingsActionTile(
                    key: const ValueKey('core-home-inventory-entry'),
                    buttonKey: const ValueKey('core-home-inventory-action'),
                    title: Text(l10n.inventoryTitle),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) context.push('/inventory');
                          },
                  ),
                if (controller.account.session?.user.canAdminister == true)
                  SettingsActionTile(
                    key: const ValueKey('core-home-resource-catalog-entry'),
                    buttonKey: const ValueKey(
                      'core-home-resource-catalog-action',
                    ),
                    title: Text(l10n.resourceCatalogEntry),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) {
                              context.push('/reservations/manage');
                            }
                          },
                  ),
                if (controller.account.context != null)
                  SettingsActionTile(
                    key: const ValueKey('core-home-reservations-entry'),
                    buttonKey: const ValueKey('core-home-reservations-action'),
                    title: Text(l10n.resourceReservationsTitle),
                    additionalInfo: Text(
                      l10n.resourceReservationsEntrySubtitle,
                    ),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) {
                              context.push('/reservations');
                            }
                          },
                  ),
                if (controller.account.context != null)
                  SettingsActionTile(
                    key: const ValueKey('core-home-documents-entry'),
                    buttonKey: const ValueKey('core-home-documents-action'),
                    title: Text(l10n.inventoryDocuments),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) context.push('/documents');
                          },
                  ),
                if (controller.account.context != null)
                  SettingsActionTile(
                    key: const ValueKey('core-home-family-board-entry'),
                    buttonKey: const ValueKey('core-home-family-board-action'),
                    title: Text(l10n.familyBoardTitle),
                    additionalInfo: Text(l10n.familyBoardEntrySubtitle),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) context.push('/family-board');
                          },
                  ),
                if (controller.account.context != null)
                  SettingsActionTile(
                    key: const ValueKey('fair-chores-entry'),
                    buttonKey: const ValueKey('fair-chores-entry-action'),
                    title: Text(l10n.fairChoresTitle),
                    additionalInfo: Text(l10n.fairChoresSubtitle),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) context.push('/chores');
                          },
                  ),
                if (controller.account.context != null)
                  SettingsActionTile(
                    key: const ValueKey('local-notification-entry'),
                    buttonKey: const ValueKey(
                      'local-notification-entry-action',
                    ),
                    title: Text(l10n.localNotificationsTitle),
                    additionalInfo: Text(l10n.localNotificationsEntrySubtitle),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) {
                              context.push('/notifications');
                            }
                          },
                  ),
                if (controller.account.context != null)
                  SettingsActionTile(
                    key: const ValueKey('core-home-weekly-menu-entry'),
                    buttonKey: const ValueKey('core-home-weekly-menu-action'),
                    title: Text(l10n.weeklyMealPlanTitle),
                    additionalInfo: Text(l10n.weeklyMealPlanEntrySubtitle),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) context.push('/weekly-menu');
                          },
                  ),
                if (controller.account.context != null)
                  SettingsActionTile(
                    key: const ValueKey('core-home-shared-expenses-entry'),
                    buttonKey: const ValueKey(
                      'core-home-shared-expenses-action',
                    ),
                    title: Text(l10n.sharedExpensesTitle),
                    additionalInfo: Text(l10n.sharedExpensesEntrySubtitle),
                    onTap: !current()
                        ? null
                        : () {
                            if (current()) {
                              context.push('/shared-expenses');
                            }
                          },
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
