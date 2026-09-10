import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/remote_access/ssh/ssh_terminal_tabs_controller.dart';

import '../remote_profiles_test.dart' show profile;
import 'ssh_session_controller_test.dart' show Engine, Security, hostPin;

void main() {
  test(
    'tabs are bounded and every connection requires an explicit action',
    () async {
      final store = Security()..pin = hostPin;
      final engines = <Engine>[];
      final tabs = SshTerminalTabsController(
        profile: profile(),
        store: store,
        engineFactory: () {
          final engine = Engine();
          engines.add(engine);
          return engine;
        },
        isCurrent: () => true,
        maxTabs: 4,
      );
      addTearDown(tabs.dispose);

      expect(tabs.tabs, hasLength(1));
      expect(engines, isEmpty);
      for (var i = 0; i < 6; i++) {
        tabs.addTab();
      }
      expect(tabs.tabs, hasLength(4));
      expect(engines, isEmpty);

      await tabs.active.controller.connect();
      expect(engines, hasLength(1));
      expect(tabs.active.controller.phase.name, 'connected');
      expect(
        tabs.tabs.where((tab) => tab.controller.phase.name == 'connected'),
        hasLength(1),
      );
    },
  );

  test(
    'closing and lifecycle retirement clean every tab without replay',
    () async {
      final store = Security()..pin = hostPin;
      final engines = <Engine>[];
      final tabs = SshTerminalTabsController(
        profile: profile(),
        store: store,
        engineFactory: () {
          final engine = Engine();
          engines.add(engine);
          return engine;
        },
        isCurrent: () => true,
      );
      addTearDown(tabs.dispose);

      await tabs.active.controller.connect();
      final first = tabs.active.id;
      expect(tabs.addTab(), isTrue);
      await tabs.active.controller.connect();
      expect(engines, hasLength(2));
      tabs.closeTab(first);
      expect(engines.first.closed, isTrue);
      expect(engines.expand((engine) => engine.channel.writes), isEmpty);
      tabs.retire();
      expect(engines.every((engine) => engine.closed), isTrue);
      expect(tabs.addTab(), isFalse);
      expect(engines, hasLength(2));
    },
  );
}
