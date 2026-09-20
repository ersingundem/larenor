import 'package:flutter/cupertino.dart';

import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/camera_snapshot.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../../media/hub/presentation/media_session_state.dart';
import 'camera_viewer_screen.dart';
import '../../../shared/theme/typography.dart';

class CamerasScreen extends ConsumerStatefulWidget {
  const CamerasScreen({super.key});

  @override
  ConsumerState<CamerasScreen> createState() => _CamerasScreenState();
}

class _CamerasScreenState extends MediaSessionState<CamerasScreen> {
  bool _current(int generation, Object reading) =>
      sessionCurrent(generation) &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent == true &&
      identical(ref.read(entitiesProvider), reading);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final exposed =
        foreground &&
        interactionActive &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent == true;
    if (!exposed) {
      return ServiceRootScaffold(
        title: l10n.settingsCameras,
        slivers: const [SliverFilledMessage(child: SizedBox.expand())],
      );
    }
    final entitiesAsync = ref.watch(entitiesProvider);
    final generation = sessionGeneration;
    final active = _current(generation, entitiesAsync);

    return ServiceRootScaffold(
      title: l10n.settingsCameras,
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            header: Semantics(
              key: const ValueKey('cameras-controls-header'),
              header: true,
              child: Text(l10n.settingsCameras),
            ),
            children: [
              SettingsActionTile(
                buttonKey: const ValueKey('cameras-refresh-action'),
                title: Text(l10n.commonRefresh),
                onTap: active
                    ? () {
                        if (_current(generation, entitiesAsync)) {
                          ref.invalidate(entitiesProvider);
                        }
                      }
                    : null,
              ),
            ],
          ),
        ),
        entitiesAsync.when(
          loading: () => const SliverFillRemaining(
            child: Center(child: CupertinoActivityIndicator()),
          ),
          error: (error, _) => SliverFillRemaining(
            child: Center(child: Text(l10n.adminLoadError(l10n.actionFailed))),
          ),
          data: (entities) {
            final cameras =
                entities.values.where((e) => e.domain == 'camera').toList()
                  ..sort((a, b) => a.friendlyName.compareTo(b.friendlyName));
            if (cameras.isEmpty) {
              return SliverFillRemaining(
                child: Center(child: Text(l10n.camerasScreenEmpty)),
              );
            }
            return SliverSafeArea(
              top: false,
              sliver: SliverPadding(
                padding: const EdgeInsets.all(12),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 360,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.3,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final camera = cameras[index];
                    return CupertinoButton(
                      key: ValueKey('camera-${camera.entityId}'),
                      minimumSize: const Size(48, 48),
                      padding: EdgeInsets.zero,
                      borderRadius: BorderRadius.circular(12),
                      onPressed: active
                          ? () {
                              if (!_current(generation, entitiesAsync)) return;
                              Navigator.of(context).push(
                                CupertinoPageRoute(
                                  builder: (_) => CameraViewerScreen(
                                    entityId: camera.entityId,
                                    title: camera.friendlyName,
                                  ),
                                ),
                              );
                            }
                          : null,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraSnapshot(entityId: camera.entityId),
                            DecoratedBox(
                              key: ValueKey(
                                'camera-label-scrim-${camera.entityId}',
                              ),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color(0x00000000),
                                    Color(0x14000000),
                                    Color(0xCC000000),
                                  ],
                                  stops: [0.35, 0.62, 1],
                                ),
                              ),
                            ),
                            Positioned(
                              left: 8,
                              right: 8,
                              bottom: 8,
                              child: Text(
                                camera.friendlyName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: CupertinoColors.white,
                                  fontSize: AppText.caption1.fontSize,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }, childCount: cameras.length),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
