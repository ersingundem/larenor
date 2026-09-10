import 'package:flutter/foundation.dart';

import '../data/remote_profiles.dart';
import 'ssh_engine.dart';
import 'ssh_security_store.dart';
import 'ssh_session_controller.dart';

class SshTerminalTab {
  const SshTerminalTab({
    required this.id,
    required this.number,
    required this.controller,
  });
  final int id;
  final int number;
  final SshSessionController controller;
}

class SshTerminalTabsController extends ChangeNotifier {
  SshTerminalTabsController({
    required this.profile,
    required this.store,
    required this.engineFactory,
    required this.isCurrent,
    this.maxTabs = 4,
  }) {
    if (maxTabs < 1 || maxTabs > 8) {
      throw ArgumentError.value(maxTabs, 'maxTabs');
    }
    _append();
  }

  final RemoteProfile profile;
  final SshSecurityStore store;
  final SshEngine Function() engineFactory;
  final bool Function() isCurrent;
  final int maxTabs;
  final List<SshTerminalTab> _tabs = [];
  int _nextId = 1, _nextNumber = 1, _selectedId = 0;
  bool _retired = false, _disposed = false;

  List<SshTerminalTab> get tabs => List.unmodifiable(_tabs);
  SshTerminalTab get active => _tabs.firstWhere((tab) => tab.id == _selectedId);
  bool get canAdd => !_retired && !_disposed && _tabs.length < maxTabs;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  SshTerminalTab _append() {
    late final SshSessionController controller;
    controller = SshSessionController(
      profile: profile,
      store: store,
      engineFactory: engineFactory,
      isCurrent: () => !_retired && !_disposed && isCurrent(),
    )..addListener(_changed);
    final tab = SshTerminalTab(
      id: _nextId++,
      number: _nextNumber++,
      controller: controller,
    );
    _tabs.add(tab);
    _selectedId = tab.id;
    return tab;
  }

  bool addTab() {
    if (!canAdd) return false;
    _append();
    _changed();
    return true;
  }

  bool selectTab(int id) {
    if (_retired || _disposed || !_tabs.any((tab) => tab.id == id)) {
      return false;
    }
    if (_selectedId == id) return true;
    _selectedId = id;
    _changed();
    return true;
  }

  bool closeTab(int id) {
    if (_retired || _disposed) return false;
    final index = _tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return false;
    final removed = _tabs.removeAt(index);
    removed.controller.removeListener(_changed);
    removed.controller.dispose();
    if (_tabs.isEmpty) {
      _append();
    } else if (_selectedId == id) {
      _selectedId = _tabs[index.clamp(0, _tabs.length - 1)].id;
    }
    _changed();
    return true;
  }

  void resizeActive(SshTerminalSize size) =>
      active.controller.resizeTerminal(size);

  void retire() {
    if (_retired || _disposed) return;
    _retired = true;
    for (final tab in _tabs) {
      tab.controller.retire();
    }
    _changed();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retired = true;
    for (final tab in _tabs) {
      tab.controller.removeListener(_changed);
      tab.controller.dispose();
    }
    _tabs.clear();
    super.dispose();
  }
}
