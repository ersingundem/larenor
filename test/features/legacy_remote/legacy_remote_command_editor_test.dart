import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/legacy_remote/data/legacy_remote_management_api.dart';
import 'package:larenor/features/legacy_remote/domain/legacy_remote_models.dart';
import 'package:larenor/features/legacy_remote/presentation/legacy_remote_command_editor_screen.dart';

const _source = LegacyRemoteSourceBinding(
  sourceId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  revision: 1,
  serviceId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  serviceRevision: 1,
  name: 'TV',
  entityId: 'remote.tv',
  commandKeys: [LegacyRemoteCommandKey.powerToggle],
  configurationTag:
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
);

class _Editor implements LegacyRemoteCommandEditorApi {
  int writes = 0;
  bool fail = false;
  @override
  Future<LegacyRemoteSourceBinding> updateSourceCommands({
    required LegacyRemoteSourceBinding source,
    required Map<LegacyRemoteCommandKey, String> upsert,
    required Set<LegacyRemoteCommandKey> remove,
  }) async {
    writes++;
    if (fail) throw StateError('offline');
    expect(upsert.values.every((name) => name == 'louder'), isTrue);
    final keys = source.commandKeys.toSet()
      ..removeAll(remove)
      ..addAll(upsert.keys);
    expect(keys, isNotEmpty);
    return LegacyRemoteSourceBinding(
      sourceId: source.sourceId,
      revision: source.revision + 1,
      serviceId: source.serviceId,
      serviceRevision: source.serviceRevision,
      name: source.name,
      entityId: source.entityId,
      commandKeys: keys.toList(),
      configurationTag: 'd' * 64,
    );
  }
}

void main() {
  testWidgets(
    'add a supported button, remove it and preserve the original mapping',
    (tester) async {
      final api = _Editor();
      LegacyRemoteSourceBinding? saved;
      await tester.pumpWidget(
        CupertinoApp(
          home: LegacyRemoteCommandEditorScreen(
            api: api,
            source: _source,
            commandLabel: (key) => key.name,
            onSaved: (value) => saved = value,
            onCancel: () {},
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('legacy-command-remove')));
      expect(api.writes, 0);
      await tester.tap(find.byKey(const ValueKey('legacy-command-choose')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('volumeUp'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('legacy-command-name')),
        'louder',
      );
      await tester.pump();
    await tester.tap(find.byKey(const ValueKey('legacy-command-save')));
      await tester.pumpAndSettle();
      expect(
        saved?.commandKeys,
        containsAll([
          LegacyRemoteCommandKey.powerToggle,
          LegacyRemoteCommandKey.volumeUp,
        ]),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('legacy-command-remove')),
      );
      await tester.tap(find.byKey(const ValueKey('legacy-command-remove')));
      await tester.pumpAndSettle();
      expect(api.writes, 2);
      expect(saved?.commandKeys, [LegacyRemoteCommandKey.powerToggle]);
      expect(saved?.revision, 3);
    },
  );

  testWidgets(
    'failed save keeps mapping and offers an editable command with no replay',
    (tester) async {
      final api = _Editor()..fail = true;
      var saved = 0;
      await tester.pumpWidget(
        CupertinoApp(
          home: LegacyRemoteCommandEditorScreen(
            api: api,
            source: _source,
            commandLabel: (key) => key.name,
            onSaved: (_) => saved++,
            onCancel: () {},
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('legacy-command-name')),
        'louder',
      );
      await tester.pump();
    await tester.tap(find.byKey(const ValueKey('legacy-command-save')));
      await tester.pumpAndSettle();
      expect(saved, 0);
      expect(api.writes, 1);
      expect(find.textContaining('could not be saved'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('legacy-command-existing-powerToggle')),
        findsOneWidget,
      );
    },
  );
}
