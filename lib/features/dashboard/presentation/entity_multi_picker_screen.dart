import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/spacing.dart';
import '../../../shared/theme/typography.dart';
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

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.title),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          // Disabled until something is picked, so the button never
          // pretends an empty selection is a valid action.
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected.toList()),
          child: Text(
            _selected.isEmpty
                ? l10n.commonAdd
                : l10n.entityPickerAddCount(_selected.length),
          ),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: CupertinoSearchTextField(
                placeholder: l10n.commonSearch,
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Padding(
                        padding: Insets.emptyState,
                        child: Text(
                          widget.emptyMessage ?? l10n.entityPickerEmpty,
                          textAlign: TextAlign.center,
                          style: AppText.emptyStateBody.copyWith(
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final entity = filtered[index];
                        final picked = _selected.contains(entity.entityId);
                        return CupertinoListTile(
                          leading: Icon(
                            iconForEntity(entity),
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                          title: Text(entity.friendlyName),
                          subtitle: Text(entity.entityId),
                          trailing: picked
                              ? Icon(
                                  CupertinoIcons.checkmark_circle_fill,
                                  color: CupertinoTheme.of(context)
                                      .primaryColor,
                                )
                              : Icon(
                                  CupertinoIcons.circle,
                                  color: CupertinoColors.tertiaryLabel
                                      .resolveFrom(context),
                                ),
                          onTap: () => setState(() {
                            if (picked) {
                              _selected.remove(entity.entityId);
                            } else {
                              _selected.add(entity.entityId);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
