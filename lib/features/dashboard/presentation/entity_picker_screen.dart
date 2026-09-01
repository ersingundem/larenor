import 'package:flutter/cupertino.dart';

import '../../../l10n/generated/app_localizations.dart';
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
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(l10n.entityPickerTitle),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoSearchTextField(
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        widget.emptyMessage ?? l10n.entityPickerEmpty,
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final entity = filtered[index];
                        return CupertinoListTile(
                          title: Text(entity.friendlyName),
                          subtitle: Text(entity.entityId),
                          onTap: () => Navigator.of(context).pop(entity),
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
