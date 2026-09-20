import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/theme/spacing.dart';
import '../../../shared/widgets/app_page_scaffold.dart';
import '../../../shared/widgets/settings_action_tile.dart';
import '../../../shared/widgets/settings_section.dart';
import '../../ha_client/data/models/ha_entity.dart';

class EntityPickerScreen extends StatefulWidget {
  const EntityPickerScreen({
    super.key,
    required this.entities,
    this.emptyMessage,
  });

  final List<HaEntity> entities;

  /// Overrides the default "No entities found" message — used to give a
  /// more specific reason (e.g. not connected at all vs. no entities of
  /// the requested domain) instead of one generic empty state for both.
  final String? emptyMessage;

  @override
  State<EntityPickerScreen> createState() => _EntityPickerScreenState();
}

class _EntityPickerScreenState extends State<EntityPickerScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.entities]
      ..sort((a, b) => a.friendlyName.compareTo(b.friendlyName));
    final filtered = _query.isEmpty
        ? sorted
        : sorted
              .where(
                (e) =>
                    e.friendlyName.toLowerCase().contains(
                      _query.toLowerCase(),
                    ) ||
                    e.entityId.toLowerCase().contains(_query.toLowerCase()),
              )
              .toList();

    final l10n = AppLocalizations.of(context);
    return AppPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.entityPickerTitle),
      ),
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: CupertinoSearchTextField(
                    key: const ValueKey('entity-picker-search'),
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
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: Insets.page,
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final entity = filtered[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: Gap.sm),
                              child: SettingsSection(
                                margin: EdgeInsets.zero,
                                children: [
                                  SettingsActionTile(
                                    buttonKey: ValueKey(
                                      'entity-picker-${entity.entityId}',
                                    ),
                                    title: Text(entity.friendlyName),
                                    additionalInfo: Text(entity.entityId),
                                    onTap: () =>
                                        Navigator.of(context).pop(entity),
                                  ),
                                ],
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
