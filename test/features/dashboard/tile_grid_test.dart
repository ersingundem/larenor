import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oikos/features/dashboard/domain/tile_config.dart';
import 'package:oikos/features/dashboard/presentation/tile_grid.dart';

void main() {
  const tile = TileConfig(
    id: 'tile-1',
    type: TileType.entity,
    x: 0,
    y: 0,
    width: 2,
    height: 2,
    entityId: 'light.kitchen',
  );

  Widget buildGrid({required bool editMode, ValueChanged<String>? onRemove}) {
    return CupertinoApp(
      home: CupertinoPageScaffold(
        child: SizedBox(
          width: 400,
          height: 400,
          child: TileGrid(
            tiles: const [tile],
            editMode: editMode,
            tileBuilder: (context, t) => Text(t.entityId ?? ''),
            onTileChanged: (_) {},
            onTileRemoved: onRemove ?? (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('renders tile content via the provided builder', (
    tester,
  ) async {
    await tester.pumpWidget(buildGrid(editMode: false));

    expect(find.text('light.kitchen'), findsOneWidget);
  });

  testWidgets('hides the remove control outside edit mode', (tester) async {
    await tester.pumpWidget(buildGrid(editMode: false));

    expect(find.byIcon(CupertinoIcons.xmark), findsNothing);
  });

  testWidgets('tapping remove in edit mode calls onTileRemoved', (
    tester,
  ) async {
    String? removedId;
    await tester.pumpWidget(
      buildGrid(editMode: true, onRemove: (id) => removedId = id),
    );

    await tester.tap(find.byIcon(CupertinoIcons.xmark));
    await tester.pump();

    expect(removedId, 'tile-1');
  });
}
