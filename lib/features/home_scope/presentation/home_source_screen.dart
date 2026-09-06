import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_session_controller.dart';
import '../../../core/home_source_store.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../media/hub/presentation/media_session_state.dart';
import '../data/home_layout_access.dart';
import 'legacy_layout_screen.dart';
import 'core_layout_archive_screen.dart';
import '../../settings/presentation/settings_file_dialog.dart';

/// Reached only through SettingsGate, including recovery from a bad preference.
class HomeSourceScreen extends ConsumerStatefulWidget {
  const HomeSourceScreen({super.key, this.onExit, this.runFileDialog, this.archiveGateCurrent});
  final SettingsFileDialogRunner? runFileDialog;
  final bool Function()? archiveGateCurrent;
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
    bool current() =>
        sessionCurrent(generation) &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent == true;
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.homeSourceTitle),
        leading: widget.onExit == null
            ? null
            : CupertinoNavigationBarBackButton(
                onPressed: () {
                  if (current()) widget.onExit!();
                },
              ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (_, _) {
            final access = homeLayoutAccess(
              controller,
              clock: ref.watch(homeLayoutClockProvider),
            );
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(l10n.homeSourceHint),
                    ),
                    if (controller.failure != null)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(l10n.homeSourceStorageError),
                      ),
                    SettingsSection(
                      children: [
                        for (final source in HomeSource.values)
                          SettingsActionTile(
                            key: ValueKey('home-source-${source.name}'),
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
                            onTap: controller.busy || !current()
                                ? null
                                : () {
                                    if (current() && !controller.busy) {
                                      controller.choose(source);
                                    }
                                  },
                          ),
                      ],
                    ),
                    if (controller.source == HomeSource.verifiedCore)
                      SettingsSection(
                        children: [
                          if (widget.runFileDialog != null && widget.archiveGateCurrent != null)
                            SettingsActionTile(
                              key: const ValueKey('core-layout-archive-entry'),
                              title: Text(l10n.coreLayoutArchiveTitle),
                              leading: const Icon(CupertinoIcons.archivebox),
                              onTap: access == null || !current() ? null : () {
                                if (!current() || !access.isCurrent || !widget.archiveGateCurrent!()) return;
                                Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => CoreLayoutArchiveScreen(
                                  gateCurrent: widget.archiveGateCurrent!, runFileDialog: widget.runFileDialog!,
                                )));
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
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
