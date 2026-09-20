import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/spacing.dart';
import '../../../shared/theme/typography.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../ha_client/data/models/ha_entity.dart';
import 'tiles/entity_icons.dart';

/// Picks several devices at once to drop into a room.
///
/// Setting a room up means adding a handful of things, so returning one
/// entity per trip through a picker would be tedious. Entities already in
/// the room are excluded by the caller rather than shown greyed out —
/// there's nothing useful to do with them here.
class EntityMultiPickerScreen extends StatefulWidget {
  const EntityMultiPickerScreen({
    super.key,
    required this.entities,
    required this.title,
    this.emptyMessage,
    this.initialEntityIds = const [],
  });

  final List<HaEntity> entities;
  final String title;
  final String? emptyMessage;
  final List<String> initialEntityIds;

  @override
  State<EntityMultiPickerScreen> createState() =>
      _EntityMultiPickerScreenState();
}

class _EntityMultiPickerScreenState extends State<EntityMultiPickerScreen> {
  final _selected = <String>{};
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initialEntityIds);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final sorted = [...widget.entities]
      ..sort((a, b) => a.friendlyName.compareTo(b.friendlyName));
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? sorted
        : sorted
              .where(
                (e) =>
                    e.friendlyName.toLowerCase().contains(query) ||
                    e.entityId.toLowerCase().contains(query),
              )
              .toList();

    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(widget.title)),
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              children: [
                SettingsSection(
                  children: [
                    SettingsActionTile(
                      buttonKey: const ValueKey('entity-multi-picker-add'),
                      leading: const Icon(CupertinoIcons.add_circled),
                      title: Text(
                        _selected.isEmpty
                            ? l10n.commonAdd
                            : l10n.entityPickerAddCount(_selected.length),
                      ),
                      onTap: _selected.isEmpty
                          ? null
                          : () => Navigator.of(context).pop(_selected.toList()),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  child: CupertinoSearchTextField(
                    key: const ValueKey('entity-multi-picker-search'),
                    placeholder: l10n.commonSearch,
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                const SizedBox(height: Gap.md),
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Padding(
                            padding: Insets.emptyState,
                            child: Text(
                              widget.emptyMessage ?? l10n.entityPickerEmpty,
                              textAlign: TextAlign.center,
                              style: AppText.emptyStateBody.copyWith(
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Gap.md,
                          ),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final entity = filtered[index];
                            final picked = _selected.contains(entity.entityId);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: Gap.sm),
                              child: Semantics(
                                key: ValueKey(
                                  'entity-multi-picker-${entity.entityId}',
                                ),
                                button: true,
                                selected: picked,
                                label:
                                    '${entity.friendlyName}, ${entity.entityId}',
                                child: CupertinoButton(
                                  minimumSize: const Size.fromHeight(48),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: Gap.md,
                                    vertical: Gap.sm,
                                  ),
                                  color: CupertinoColors
                                      .secondarySystemGroupedBackground
                                      .resolveFrom(context),
                                  onPressed: () => setState(() {
                                    if (picked) {
                                      _selected.remove(entity.entityId);
                                    } else {
                                      _selected.add(entity.entityId);
                                    }
                                  }),
                                  child: ExcludeSemantics(
                                    child: Row(
                                      children: [
                                        Icon(
                                          iconForEntity(entity),
                                          color: CupertinoColors.secondaryLabel
                                              .resolveFrom(context),
                                        ),
                                        const SizedBox(width: Gap.md),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(entity.friendlyName),
                                              Text(
                                                entity.entityId,
                                                style: TextStyle(
                                                  color: CupertinoColors
                                                      .secondaryLabel
                                                      .resolveFrom(context),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Icon(
                                          picked
                                              ? CupertinoIcons
                                                    .checkmark_circle_fill
                                              : CupertinoIcons.circle,
                                          color: picked
                                              ? CupertinoTheme.of(context)
                                                    .primaryColor
                                              : CupertinoColors.tertiaryLabel
                                                    .resolveFrom(context),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
