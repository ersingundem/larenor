import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/dashboard/presentation/tiles/home_accessory_tile.dart';
import 'package:larenor/features/ha_client/data/models/ha_entity.dart';
import 'package:larenor/features/ha_client/providers/ha_client_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

HaEntity entity(
  String id, {
  String state = 'on',
  Map<String, dynamic> attributes = const {},
}) => HaEntity(entityId: id, state: state, attributes: attributes);

Widget wrap(Widget child) => ProviderScope(
  child: CupertinoApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: CupertinoPageScaffold(
      child: SizedBox(width: 200, height: 130, child: child),
    ),
  ),
);

class ControlledEntities extends Entities {
  final Completer<void> operation = Completer<void>();
  int calls = 0;
  @override
  Future<Map<String, HaEntity>> build() async => {};
  @override
  Future<void> toggle(HaEntity entity) {
    calls++;
    return operation.future;
  }
}

void main() {
  group('tapTogglesEntity', () {
    test('is true for switchable accessories and scenes', () {
      expect(tapTogglesEntity(entity('light.a')), isTrue);
      expect(tapTogglesEntity(entity('switch.a')), isTrue);
      expect(tapTogglesEntity(entity('scene.movie')), isTrue);
    });

    test('is false for locks and covers, which have no turn_on service', () {
      expect(tapTogglesEntity(entity('lock.front')), isFalse);
      expect(tapTogglesEntity(entity('cover.garage')), isFalse);
    });

    test('is false for read-only accessories', () {
      expect(tapTogglesEntity(entity('camera.porch')), isFalse);
      expect(tapTogglesEntity(entity('sensor.temp')), isFalse);
    });
  });

  group('HomeAccessoryTile', () {
    testWidgets(
      'suppresses duplicate commands and shows a recoverable failure',
      (tester) async {
        final notifier = ControlledEntities();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [entitiesProvider.overrideWith(() => notifier)],
            child: CupertinoApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: CupertinoPageScaffold(
                child: SizedBox(
                  width: 200,
                  height: 130,
                  child: HomeAccessoryTile(entity: entity('light.kitchen')),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(HomeAccessoryTile));
        await tester.pump();
        await tester.tap(find.byType(HomeAccessoryTile));
        expect(notifier.calls, 1);
        notifier.operation.completeError(StateError('offline'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Could not update this accessory. Check the connection and try again.',
          ),
          findsOneWidget,
        );
        expect(find.byType(CupertinoActivityIndicator), findsNothing);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('shows the friendly name and an On state', (tester) async {
      await tester.pumpWidget(
        wrap(
          HomeAccessoryTile(
            entity: entity(
              'light.kitchen',
              attributes: const {'friendly_name': 'Kitchen'},
            ),
          ),
        ),
      );

      expect(find.text('Kitchen'), findsOneWidget);
      expect(find.text('On'), findsOneWidget);
    });

    testWidgets('shows Off when the entity is off', (tester) async {
      await tester.pumpWidget(
        wrap(
          HomeAccessoryTile(
            entity: entity(
              'light.kitchen',
              state: 'off',
              attributes: const {'friendly_name': 'Kitchen'},
            ),
          ),
        ),
      );

      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('prefers a sensor reading over the raw state', (tester) async {
      await tester.pumpWidget(
        wrap(
          HomeAccessoryTile(
            entity: entity(
              'sensor.hallway',
              state: '21.5',
              attributes: const {
                'friendly_name': 'Hallway',
                'device_class': 'temperature',
                'unit_of_measurement': '°C',
              },
            ),
          ),
        ),
      );

      expect(find.text('21.5°C'), findsOneWidget);
    });

    testWidgets('falls back to the entity id when unnamed', (tester) async {
      await tester.pumpWidget(
        wrap(HomeAccessoryTile(entity: entity('light.x'))),
      );

      expect(find.text('light.x'), findsOneWidget);
    });
  });
}
