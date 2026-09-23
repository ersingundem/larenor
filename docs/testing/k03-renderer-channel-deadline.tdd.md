# K03 renderer channel deadline TDD evidence

This slice bounds the Android WebView renderer attachment boundary. It carries
only the plugin WebView id, an opaque attachment id and exact allowed origins;
URLs, paths, cookies, headers and credentials never cross this channel. K03
remains pending because its full transfer, intent, authentication, certificate
and physical renderer matrix is wider than this slice.

## Three accepted behaviors

1. Native `attach` has a four-second total deadline. Timeout revokes the Dart
   callback immediately; a later positive native acknowledgement receives an
   exact best-effort `detach` and cannot recover a newer WebView.
2. Handle disposal revokes the callback before native I/O, sends one exact
   detach, and returns after the same bounded deadline even if Android never
   acknowledges it. Repeated disposal sends no second command.
3. A renderer-gone callback is one-shot. Unknown, malformed and stale ids are
   ignored, while a local UI callback failure is contained and never becomes a
   platform-channel error or exposes its message.

## RED and GREEN

Commit `17a95adf75b33881fa0910509793b00cb4435159` defined the three failing
boundaries. The old implementation had no channel-owned deadline, could wait
forever for detach, and allowed a callback exception to cross the channel.

Commit `581b873a26f919f6a3555decf1f67498413b599c` added explicit operation
ownership, timeout cleanup and exception containment.

```text
flutter test test/features/web_panel/web_panel_renderer_monitor_test.dart
# 6 passed
flutter test test/features/web_panel
# 105 passed
flutter analyze lib/features/web_panel/data/web_panel_renderer_monitor.dart test/features/web_panel/web_panel_renderer_monitor_test.dart
# No issues found
```

Security policy, queue validation, per-commit progress and diff checks run on
the final exact head. Progress stays 26/125 and 0/63 until the complete K03
acceptance and required CI evidence are present.
