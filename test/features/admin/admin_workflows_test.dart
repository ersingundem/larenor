import 'dart:convert';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:larenor/features/admin/data/admin_client.dart';
import 'package:larenor/features/admin/data/models/flow_schema_field.dart';
import 'package:larenor/features/admin/data/models/ha_area.dart';
import 'package:larenor/features/admin/data/models/ha_device.dart';
import 'package:larenor/features/admin/data/models/ha_registry_entry.dart';
import 'package:larenor/features/admin/presentation/add_integration_screen.dart';
import 'package:larenor/features/admin/presentation/areas_screen.dart';
import 'package:larenor/features/admin/presentation/automation_editor_screen.dart';
import 'package:larenor/features/admin/presentation/registry_editor_screen.dart';
import 'package:larenor/features/admin/presentation/widgets/dynamic_form_field.dart';
import 'package:larenor/features/admin/providers/admin_providers.dart';
import 'package:larenor/features/dashboard/data/dashboard_repository.dart';
import 'package:larenor/features/dashboard/domain/dashboard_layout.dart';
import 'package:larenor/features/dashboard/domain/dashboard_room.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'admin_test_fakes.dart';

Future<void> openScreen(
  WidgetTester tester,
  Widget screen,
  HaAdminClient client,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        haAdminClientProvider.overrideWithValue(client),
        areasProvider.overrideWith(
          (_) async => const [HaArea(areaId: 'kitchen', name: 'Kitchen')],
        ),
      ],
      child: CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => CupertinoPageScaffold(
            child: Center(
              child: CupertinoButton(
                child: const Text('Open editor'),
                onPressed: () => Navigator.push(
                  context,
                  CupertinoPageRoute<void>(builder: (_) => screen),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'registry save is single-flight and background invalidates local rename',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repository = DashboardRepository();
      await repository.save(
        const DashboardLayout(
          rooms: [
            DashboardRoom(
              id: 'room',
              name: 'Room',
              entityIds: ['light.kitchen'],
            ),
          ],
        ),
      );
      final pending = Completer<dynamic>();
      final socket = RecordingAdminSocket(respond: (_) => pending.future);
      await openScreen(
        tester,
        const RegistryEditorScreen.entity(
          HaRegistryEntry(entityId: 'light.kitchen'),
        ),
        fakeAdminClient(socket),
      );
      await tester.enterText(
        find.byType(CupertinoTextFormFieldRow).at(1),
        'light.dining',
      );
      final save = tester
          .widget<CupertinoButton>(find.widgetWithText(CupertinoButton, 'Save'))
          .onPressed!;
      save();
      save();
      await tester.pump();
      expect(socket.commands, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      pending.complete(<String, dynamic>{});
      await tester.pumpAndSettle();
      expect((await repository.load()).rooms.single.entityIds, [
        'light.kitchen',
      ]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      save();
      expect(socket.commands, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an old registry draft cannot write to a replacement client', (
    tester,
  ) async {
    final oldSocket = RecordingAdminSocket();
    final replacementSocket = RecordingAdminSocket();
    await openScreen(
      tester,
      const RegistryEditorScreen.entity(
        HaRegistryEntry(entityId: 'light.kitchen'),
      ),
      fakeAdminClient(oldSocket),
    );
    await tester.enterText(
      find.byType(CupertinoTextFormFieldRow).first,
      'New name',
    );
    final save = tester
        .widget<CupertinoButton>(find.widgetWithText(CupertinoButton, 'Save'))
        .onPressed!;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RegistryEditorScreen)),
    );
    container.updateOverrides([
      haAdminClientProvider.overrideWithValue(
        fakeAdminClient(replacementSocket),
      ),
      areasProvider.overrideWith(
        (_) async => const [HaArea(areaId: 'kitchen', name: 'Kitchen')],
      ),
    ]);
    await tester.pumpAndSettle();
    save();
    await tester.pump();
    expect(oldSocket.commands, isEmpty);
    expect(replacementSocket.commands, isEmpty);
    expect(
      tester
          .widget<CupertinoButton>(find.widgetWithText(CupertinoButton, 'Save'))
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'successful entity ID rename migrates saved local room references',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repository = DashboardRepository();
      await repository.save(
        const DashboardLayout(
          rooms: [
            DashboardRoom(
              id: 'local-room',
              name: 'My room',
              entityIds: ['light.kitchen'],
            ),
          ],
          favoriteEntityIds: ['light.kitchen'],
        ),
      );
      final socket = RecordingAdminSocket();
      await openScreen(
        tester,
        const RegistryEditorScreen.entity(
          HaRegistryEntry(entityId: 'light.kitchen'),
        ),
        fakeAdminClient(socket),
      );
      await tester.enterText(
        find.byType(CupertinoTextFormFieldRow).at(1),
        'light.dining',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(socket.commands.single['new_entity_id'], 'light.dining');
      final layout = await repository.load();
      expect(layout.rooms.single.entityIds, ['light.dining']);
      expect(layout.favoriteEntityIds, ['light.dining']);
      expect(find.text('Open editor'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native multi-select picker returns typed values after selection',
    (tester) async {
      dynamic selected;
      final field = FlowSchemaField.fromJson({
        'name': 'levels',
        'type': 'multi_select',
        'options': [
          [1, 'Low'],
          [2, 'High'],
        ],
      });
      await openScreen(
        tester,
        CupertinoPageScaffold(
          child: SafeArea(
            child: DynamicFormField(
              field: field,
              value: const [1],
              onChanged: (value) => selected = value,
            ),
          ),
        ),
        fakeAdminClient(RecordingAdminSocket()),
      );
      await tester.tap(find.text('Levels'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(selected, [1, 2]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'raw JSON editor distinguishes user text from typed schema strings',
    (tester) async {
      dynamic edited;
      final field = FlowSchemaField.fromJson({
        'name': 'advanced',
        'default': 'plain token',
      });
      await openScreen(
        tester,
        CupertinoPageScaffold(
          child: SafeArea(
            child: DynamicFormField(
              field: field,
              value: null,
              onChanged: (value) => edited = value,
            ),
          ),
        ),
        fakeAdminClient(RecordingAdminSocket()),
      );
      expect(find.text('"plain token"'), findsOneWidget);
      await tester.enterText(
        find.byType(CupertinoTextFormFieldRow),
        '{"duration":3}',
      );
      expect(edited, isA<RawFlowJsonInput>());
      expect(normalizeFlowValues([field], {'advanced': edited}), {
        'advanced': {'duration': 3},
      });
    },
  );

  testWidgets(
    'device editor clears name and area explicitly without changing other fields',
    (tester) async {
      final socket = RecordingAdminSocket();
      await openScreen(
        tester,
        const RegistryEditorScreen.device(
          HaDevice(
            id: 'hub',
            name: 'Original hub',
            nameByUser: 'My hub',
            areaId: 'kitchen',
            disabledBy: 'integration',
          ),
        ),
        fakeAdminClient(socket),
      );
      await tester.enterText(find.byType(CupertinoTextFormFieldRow).first, '');
      await tester.tap(find.text('Area'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('None'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(socket.commands.single, {
        'type': 'config/device_registry/update',
        'device_id': 'hub',
        'name_by_user': null,
        'area_id': null,
      });
      expect(find.text('Open editor'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'entity name edit preserves icon, ID and inherited disabled state',
    (tester) async {
      final socket = RecordingAdminSocket();
      await openScreen(
        tester,
        const RegistryEditorScreen.entity(
          HaRegistryEntry(
            entityId: 'light.kitchen',
            originalName: 'Kitchen',
            icon: 'mdi:ceiling-light',
            disabledBy: 'device',
          ),
        ),
        fakeAdminClient(socket),
      );
      await tester.enterText(
        find.byType(CupertinoTextFormFieldRow).first,
        'Dining light',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(socket.commands.single, {
        'type': 'config/entity_registry/update',
        'entity_id': 'light.kitchen',
        'name': 'Dining light',
      });
    },
  );

  testWidgets(
    'entity ID changes to another domain rejected before any mutation',
    (tester) async {
      final socket = RecordingAdminSocket();
      await openScreen(
        tester,
        const RegistryEditorScreen.entity(
          HaRegistryEntry(entityId: 'light.kitchen', originalName: 'Kitchen'),
        ),
        fakeAdminClient(socket),
      );
      await tester.enterText(
        find.byType(CupertinoTextFormFieldRow).at(1),
        'switch.kitchen',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(socket.commands, isEmpty);
      expect(find.text('Enter a valid value for this field.'), findsOneWidget);
    },
  );

  testWidgets(
    'area creation is a usable native dialog and writes trimmed name',
    (tester) async {
      final socket = RecordingAdminSocket();
      await openScreen(tester, const AreasScreen(), fakeAdminClient(socket));
      await tester.tap(find.byIcon(CupertinoIcons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField), '  Office  ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(socket.commands.single, {
        'type': 'config/area_registry/create',
        'name': 'Office',
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'flow keeps typed input after server validation error and retries same data',
    (tester) async {
      final submitted = <Map<String, dynamic>>[];
      Map<String, dynamic> form({bool error = false}) => {
        'type': 'form',
        'flow_id': 'flow1',
        'step_id': 'user',
        'data_schema': [
          {'name': 'host', 'type': 'string', 'required': true},
          {'name': 'port', 'type': 'integer', 'default': 8123},
          {'name': 'ssl', 'type': 'boolean', 'required': true},
          {'name': 'unused', 'type': 'string'},
        ],
        'errors': error ? {'base': 'cannot_connect'} : {},
      };
      final client = fakeAdminClient(
        RecordingAdminSocket(),
        respond: (request) async {
          if (request.url.path.endsWith('/flow')) {
            return http.Response(jsonEncode(form()), 200);
          }
          if (request.method == 'DELETE') return http.Response('{}', 200);
          submitted.add(
            Map<String, dynamic>.from(jsonDecode(request.body) as Map),
          );
          return http.Response(jsonEncode(form(error: true)), 200);
        },
      );
      await openScreen(
        tester,
        const AddIntegrationScreen(handler: 'hue'),
        client,
      );
      await tester.enterText(
        find.byType(CupertinoTextFormFieldRow).first,
        'ha.local',
      );
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('base: cannot_connect'), findsOneWidget);
      expect(find.text('ha.local'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(submitted, [
        {'host': 'ha.local', 'port': 8123, 'ssl': false},
        {'host': 'ha.local', 'port': 8123, 'ssl': false},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'duplicated automation must save under a fresh ID even if source ID remains in JSON',
    (tester) async {
      http.Request? saved;
      final client = fakeAdminClient(
        RecordingAdminSocket(),
        respond: (request) async {
          saved = request;
          return http.Response('{}', 200);
        },
      );
      await openScreen(
        tester,
        const AutomationEditorScreen(
          initialConfig: {
            'id': 'source-id',
            'alias': 'A copy',
            'triggers': [],
            'conditions': [],
            'actions': [],
          },
        ),
        client,
      );
      expect(saved, isNull);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved!.method, 'POST');
      final payload = jsonDecode(saved!.body) as Map;
      expect(payload['id'], isNot('source-id'));
      expect(saved!.url.path, '/api/config/automation/config/${payload['id']}');
      expect(payload['alias'], 'A copy');
    },
  );
}
