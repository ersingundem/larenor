import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/service_root_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../dashboard/presentation/dashboard_edit_guard.dart';
import '../data/home_resources_providers.dart';
import '../domain/home_resource_models.dart';

class CoreResourcePickerScreen extends ConsumerStatefulWidget {
  const CoreResourcePickerScreen({super.key, required this.kind});
  final HomeResourceKind kind;

  @override
  ConsumerState<CoreResourcePickerScreen> createState() =>
      _CoreResourcePickerScreenState();
}

class _CoreResourcePickerScreenState
    extends DashboardEditState<CoreResourcePickerScreen> {
  String _query = '';
  bool _expired = false, _returned = false;

  @override
  void invalidateDashboardInteraction() => _expired = true;

  void _select(HomeResourceRecord rendered) {
    if (_expired || _returned || !interactionCurrent(interactionGeneration)) {
      return;
    }
    final catalog = ref.read(sharedHomeResourcesProvider);
    if (catalog == null || !catalog.fresh || catalog.stale) return;
    final current = catalog.entries.where((entry) {
      return entry.context == rendered.context &&
          entry.id == rendered.id &&
          entry.kind == rendered.kind &&
          entry.revision == rendered.revision &&
          entry.aclRevision == rendered.aclRevision;
    }).firstOrNull;
    if (current == null || ModalRoute.of(context)?.isCurrent != true) return;
    _returned = true;
    Navigator.pop(context, current);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final catalog = ref.watch(sharedHomeResourcesProvider);
    final usable = !_expired && catalog?.fresh == true && !catalog!.stale;
    final query = _query.trim().toLowerCase();
    final entries =
        <HomeResourceRecord>[
          for (final entry in catalog?.entries ?? const <HomeResourceRecord>[])
            if (entry.kind == widget.kind &&
                (query.isEmpty || entry.label.toLowerCase().contains(query)))
              entry,
        ]..sort((a, b) {
          final order = a.order.compareTo(b.order);
          return order == 0 ? a.id.compareTo(b.id) : order;
        });
    return ServiceRootScaffold(
      title: l10n.homeResourcesTitle,
      trailing: CupertinoButton(
        minimumSize: const Size.square(48),
        padding: EdgeInsets.zero,
        onPressed: () => closeDashboardModal(context),
        child: Text(l10n.commonCancel),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: SettingsSection(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CupertinoSearchTextField(
                      key: const ValueKey('core-resource-picker-search'),
                      placeholder: l10n.commonSearch,
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    if (!usable)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          catalog?.busy == true
                              ? l10n.homeResourcesLoading
                              : l10n.homeCoreVerificationRequired,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SliverList.builder(
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            return SettingsSection(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              children: [
                SettingsActionTile(
                  buttonKey: ValueKey('core-resource-picker-${entry.id}'),
                  leading: Icon(
                    entry.kind == HomeResourceKind.room
                        ? CupertinoIcons.house
                        : CupertinoIcons.square_stack_3d_up,
                  ),
                  title: Text(entry.label),
                  additionalInfo: Text(
                    entry.kind == HomeResourceKind.room
                        ? l10n.homeResourcesRoom
                        : l10n.homeResourcesResource,
                  ),
                  onTap: usable ? () => _select(entry) : null,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
