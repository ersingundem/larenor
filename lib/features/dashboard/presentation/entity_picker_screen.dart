import 'package:flutter/cupertino.dart';

import '../../ha_client/data/models/ha_entity.dart';

class EntityPickerScreen extends StatefulWidget {
  const EntityPickerScreen({super.key, required this.entities});

  final List<HaEntity> entities;

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

    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Add Entity')),
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
                  ? const Center(child: Text('No entities found'))
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
