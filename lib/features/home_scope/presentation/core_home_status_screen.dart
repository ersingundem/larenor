import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/app_interaction_scope.dart';
import '../../home_resources/presentation/core_home_resources.dart';
import '../../../core/home_session_controller.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';

/// Core metadata and independent account recovery; no home adapters are mounted.
class CoreHomeStatusScreen extends ConsumerWidget {
  const CoreHomeStatusScreen({super.key});
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
    return AppPageScaffold(
      child: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (_, _) => Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(24),
                    sliver: SliverMainAxisGroup(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Semantics(
                                header: true,
                                child: Text(
                                  l10n.homeSourceCore,
                                  style: CupertinoTheme.of(context)
                                      .textTheme
                                      .navLargeTitleTextStyle,
                                ),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                controller.failure != null
                                    ? l10n.homeSourceStorageError
                                    : controller.busy
                                    ? l10n.homeSourceLoading
                                    : controller.account.context != null
                                    ? l10n.homeCoreVerified
                                    : l10n.homeCoreVerificationRequired,
                              ),
                              const SizedBox(height: 16),
                              Text(l10n.homeCoreUnavailable),
                              const SizedBox(height: 24),
                              SettingsSection(
                                children: [
                                  if (controller.failure == null &&
                                      !controller.busy)
                                    SettingsActionTile(
                                      title: Text(l10n.homeCoreManageAccount),
                                      onTap: !current()
                                          ? null
                                          : () {
                                              if (current()) {
                                                context.push('/settings');
                                              }
                                            },
                                    ),
                                  SettingsActionTile(
                                    title: Text(l10n.homeSourceTitle),
                                    onTap: controller.busy || !current()
                                        ? null
                                        : () {
                                            if (current()) {
                                              context.push(
                                                '/settings/home-source',
                                              );
                                            }
                                          },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const CoreHomeResources(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
