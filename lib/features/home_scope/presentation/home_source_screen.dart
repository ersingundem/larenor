import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../core/window/window_policy_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../data/home_layout_access.dart';
import 'legacy_layout_screen.dart';
import 'core_layout_archive_screen.dart';
import '../../settings/presentation/settings_file_dialog.dart';
import '../../settings/presentation/settings_gate_screen.dart';

/// Reached only through SettingsGate, including recovery from a bad preference.
class HomeSourceScreen extends ConsumerStatefulWidget {
  const HomeSourceScreen({
    super.key,
    this.onExit,
    this.runFileDialog,
    this.archiveGateCurrent,
    this.transferGateCurrent,
  });
  final SettingsFileDialogRunner? runFileDialog;
  final bool Function()? archiveGateCurrent;
  final bool Function()? transferGateCurrent;
  final VoidCallback? onExit;
  @override
  ConsumerState<HomeSourceScreen> createState() => _HomeSourceScreenState();
}

class _HomeSourceScreenState extends MediaSessionState<HomeSourceScreen> {
  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(homeSessionControllerProvider)!;
    final l10n = AppLocalizations.of(context);
    final generation = sessionGeneration;
    ref.watch(windowPolicySnapshotProvider);
    bool current() =>
        sessionCurrent(generation) &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent == true;
    return ServiceRootScaffold(
      title: l10n.homeSourceTitle,
      leading: widget.onExit == null
          ? null
          : CupertinoNavigationBarBackButton(
              onPressed: () {
                if (current()) widget.onExit!();
              },
            ),
      slivers: [
        SliverToBoxAdapter(
          child: ListenableBuilder(
            listenable: Listenable.merge([controller, controller.account]),
            builder: (_, _) {
              final access = homeLayoutAccess(
                controller,
                clock: ref.watch(homeLayoutClockProvider),
              );
              final account = controller.account,
                  session = account.session,
                  accountGeneration = account.generation,
                  identity = controller.runtimeIdentity;
              bool selectionCurrent(HomeSource source) =>
                  current() &&
                  !controller.busy &&
                  controller.runtimeIdentity == identity &&
                  (controller.failure != null || controller.source != source);
              bool transferWindow() {
                final state = ref.read(windowPolicySnapshotProvider);
                if (state.isLoading || state.hasError || !state.hasValue) {
                  return false;
                }
                final value = state.requireValue;
                return !value.supported ||
                    value.isResumed &&
                        value.hasWindowFocus &&
                        !value.isPictureInPicture;
              }

              bool transferCurrent() =>
                  current() &&
                  transferWindow() &&
                  widget.transferGateCurrent?.call() == true &&
                  controller.source == HomeSource.directLocal &&
                  !controller.busy &&
                  controller.failure == null &&
                  controller.runtimeIdentity == identity &&
                  account.initialized &&
                  !account.working &&
                  !account.hasPendingContext &&
                  account.isCurrent(accountGeneration) &&
                  identical(account.session, session) &&
                  session != null &&
                  session.context != null &&
                  session.user.canAdminister &&
                  !session.user.mustChangePassword &&
                  !session.authMutationPending &&
                  !session.expiresSoon(DateTime.now());
              return Column(
                children: [
                  if (controller.failure != null)
                    _HomeSourceStatus(label: l10n.homeSourceStorageError)
                  else if (controller.busy)
                    _HomeSourceStatus(label: l10n.commonLoading, loading: true),
                  SettingsSection(
                    footer: Text(l10n.homeSourceHint),
                    children: [
                      for (final source in HomeSource.values)
                        SettingsActionTile(
                          key: ValueKey('home-source-${source.name}'),
                          buttonKey: ValueKey(
                            'home-source-action-${source.name}',
                          ),
                          leading:
                              controller.source == source &&
                                  controller.failure == null
                              ? const Icon(CupertinoIcons.check_mark)
                              : const SizedBox.shrink(),
                          title: Text(
                            source == HomeSource.directLocal
                                ? l10n.homeSourceDirect
                                : l10n.homeSourceCore,
                          ),
                          additionalInfo: Text(
                            source == HomeSource.directLocal
                                ? l10n.homeSourceDirectHint
                                : l10n.homeSourceCoreHint,
                          ),
                          selected:
                              controller.source == source &&
                              controller.failure == null,
                          onTap: !selectionCurrent(source)
                              ? null
                              : () {
                                  if (selectionCurrent(source)) {
                                    controller.choose(source);
                                  }
                                },
                        ),
                    ],
                  ),
                  if (controller.source == HomeSource.directLocal)
                    SettingsSection(
                      children: [
                        SettingsActionTile(
                          key: const ValueKey('core-ha-transfer-entry'),
                          title: Text(l10n.coreHaTransferTitle),
                          additionalInfo: Text(
                            transferCurrent()
                                ? l10n.coreHaTransferHint
                                : l10n.coreHaTransferRequired,
                          ),
                          onTap: !transferCurrent()
                              ? null
                              : () {
                                  if (!transferCurrent()) return;
                                  final parentGate =
                                      widget.transferGateCurrent!;
                                  Navigator.of(context).push(
                                    CupertinoPageRoute<void>(
                                      builder: (_) => SettingsGateScreen(
                                        initialDestination:
                                            SettingsGateDestination
                                                .coreHaTransfer,
                                        transferParentCurrent: parentGate,
                                      ),
                                    ),
                                  );
                                },
                        ),
                      ],
                    ),
                  if (controller.source == HomeSource.verifiedCore)
                    SettingsSection(
                      children: [
                        if (widget.runFileDialog != null &&
                            widget.archiveGateCurrent != null)
                          SettingsActionTile(
                            key: const ValueKey('core-layout-archive-entry'),
                            title: Text(l10n.coreLayoutArchiveTitle),
                            leading: const Icon(CupertinoIcons.archivebox),
                            onTap: access == null || !current()
                                ? null
                                : () {
                                    if (!current() ||
                                        !access.isCurrent ||
                                        !widget.archiveGateCurrent!()) {
                                      return;
                                    }
                                    Navigator.of(context).push(
                                      CupertinoPageRoute<void>(
                                        builder: (_) => CoreLayoutArchiveScreen(
                                          gateCurrent:
                                              widget.archiveGateCurrent!,
                                          runFileDialog: widget.runFileDialog!,
                                        ),
                                      ),
                                    );
                                  },
                          ),
                        SettingsActionTile(
                          key: const ValueKey('home-layout-preview-entry'),
                          title: Text(l10n.homeLayoutPreviewTitle),
                          additionalInfo: access == null
                              ? Text(l10n.homeLayoutUnavailable)
                              : null,
                          onTap: access == null || !current()
                              ? null
                              : () {
                                  if (current() && access.isCurrent) {
                                    Navigator.of(context).push(
                                      CupertinoPageRoute<void>(
                                        builder: (_) =>
                                            const LegacyLayoutScreen(),
                                      ),
                                    );
                                  }
                                },
                        ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HomeSourceStatus extends StatelessWidget {
  const _HomeSourceStatus({required this.label, this.loading = false});

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) => Semantics(
    key: const ValueKey('home-source-status'),
    container: true,
    liveRegion: true,
    label: label,
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          if (loading) ...[
            const CupertinoActivityIndicator(),
            const SizedBox(width: 12),
          ],
          Expanded(child: Text(label)),
        ],
      ),
    ),
  );
}
