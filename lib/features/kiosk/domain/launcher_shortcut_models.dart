enum LauncherShortcutAction {
  home('/'),
  kiosk('/settings/kiosk');

  const LauncherShortcutAction(this.location);
  final String location;

  static LauncherShortcutAction? parse(Object? raw) => switch (raw) {
    'home' => LauncherShortcutAction.home,
    'kiosk' => LauncherShortcutAction.kiosk,
    _ => null,
  };
}

final class LauncherShortcutException implements Exception {
  const LauncherShortcutException();
  @override
  String toString() => 'Launcher shortcut unavailable';
}
