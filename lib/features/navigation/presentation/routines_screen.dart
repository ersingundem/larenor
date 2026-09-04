import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/icon_badge.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../ha_client/data/models/ha_entity.dart';
import '../../ha_client/providers/ha_client_providers.dart';
import '../search/domain/local_search_index.dart';
import 'app_shell_actions.dart';

class RoutinesScreen extends ConsumerStatefulWidget {
  const RoutinesScreen({super.key});

  @override
  ConsumerState<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends ConsumerState<RoutinesScreen> {
  String _query = '';
  String _domain = 'all';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entities = ref.watch(entitiesProvider.select(_RoutineCatalog.from));
    final routines = entities.routines;
    final terms = foldSearchText(_query)
        .split(' ')
        .where((term) => term.isNotEmpty);
    final visible =
        routines.where((entity) {
          if (_domain != 'all' && entity.domain != _domain) return false;
          final text = foldSearchText(
            '${entity.friendlyName} ${entity.entityId}',
          );
          return terms.every(text.contains);
        }).toList()..sort((a, b) {
          final order = foldSearchText(a.friendlyName)
              .compareTo(foldSearchText(b.friendlyName));
          return order == 0 ? a.entityId.compareTo(b.entityId) : order;
        });

    return AppPageScaffold(
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(l10n.navigationRoutines),
            trailing: const AppShellActions(),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CupertinoSearchTextField(
                    key: const ValueKey('routines-search'),
                    placeholder: l10n.navigationSearch,
                    onChanged: (value) => setState(() => _query = value),
                  ),
                  const SizedBox(height: 12),
                  CupertinoSlidingSegmentedControl<String>(
                    key: const ValueKey('routines-filter'),
                    groupValue: _domain,
                    children: {
                      'all': Text(l10n.homeCategoryAll),
                      'scene': Text(l10n.navigationSearchScene),
                      'script': Text(l10n.navigationSearchScript),
                    },
                    onValueChanged: (value) {
                      if (value != null) setState(() => _domain = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.navigationRoutineHint,
                    style: TextStyle(
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (entities.hasError)
            SliverToBoxAdapter(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.commonError),
                  CupertinoButton(
                    onPressed: () => ref.invalidate(entitiesProvider),
                    child: Text(l10n.commonRetry),
                  ),
                ],
              ),
            ),
          if (entities.isLoading && routines.isEmpty)
            const SliverFilledMessage(child: CupertinoActivityIndicator())
          else if (visible.isEmpty && !entities.hasError)
            SliverFilledMessage(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  routines.isEmpty
                      ? l10n.navigationNoRoutines
                      : l10n.navigationSearchEmpty,
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              sliver: SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final entity = visible[index];
                  final scene = entity.domain == 'scene';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CupertinoListTile(
                        key: ValueKey('routine-${entity.entityId}'),
                        backgroundColor: CupertinoColors
                            .secondarySystemGroupedBackground
                            .resolveFrom(context),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        leading: IconBadge(
                          icon: scene
                              ? CupertinoIcons.sparkles
                              : CupertinoIcons.play_rectangle,
                          color: scene
                              ? CupertinoColors.systemOrange
                              : CupertinoColors.systemIndigo,
                        ),
                        title: Text(entity.friendlyName, maxLines: 2),
                        subtitle: Text(
                          scene
                              ? l10n.navigationSearchScene
                              : l10n.navigationSearchScript,
                        ),
                        trailing: const CupertinoListTileChevron(),
                        onTap: () => context.push(
                          '/entities/${Uri.encodeComponent(entity.entityId)}',
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Sensor updates should not rebuild or resort this page's routine collection.
class _RoutineCatalog {
  _RoutineCatalog.from(AsyncValue<Map<String, HaEntity>> state)
    : isLoading = state.isLoading,
      hasError = state.hasError,
      routines = [
        for (final entity in state.value?.values ?? const <HaEntity>[])
          if (entity.domain == 'scene' || entity.domain == 'script') entity,
      ];

  final bool isLoading;
  final bool hasError;
  final List<HaEntity> routines;

  @override
  bool operator ==(Object other) =>
      other is _RoutineCatalog &&
      isLoading == other.isLoading &&
      hasError == other.hasError &&
      listEquals(routines, other.routines);

  @override
  int get hashCode =>
      Object.hash(isLoading, hasError, Object.hashAll(routines));
}
