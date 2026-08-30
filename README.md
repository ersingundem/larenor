# Oikos

A private, custom Home Assistant companion app built with Flutter. Oikos connects to
an existing self-hosted Home Assistant server over its REST and WebSocket APIs and
provides:

- A visual dashboard builder — drag/resize tiles instead of hand-editing Lovelace YAML.
- An Android tablet "wall panel" mode — the app can be set as the device's default
  Home launcher, stays awake, and shows live dashboards or embedded web pages fullscreen.

This is not a fork of Home Assistant. It is a standalone client; you still need a
running Home Assistant instance on your network.

This repository and its contents are proprietary — see [LICENSE](LICENSE).

## Status

Early development (MVP slice): connect via server URL + long-lived access token, view
and toggle entities, build a basic dashboard with entity and fullscreen-webview tiles.

## Development setup (macOS)

```sh
brew install --cask temurin@17 flutter android-commandlinetools
flutter doctor --android-licenses
flutter doctor -v
```

Then, from the repo root:

```sh
flutter pub get
dart run build_runner build
flutter run
```

Generated code (`*.g.dart`, `*.freezed.dart`) is not committed — regenerate it
with the `build_runner` command above after every checkout or after changing
any `@freezed`/`@riverpod`/`@JsonSerializable`-annotated file. If you hit
stale/conflicting generated output, run `dart run build_runner clean` first.

## Useful commands

```sh
flutter analyze              # static analysis
flutter test                 # unit + widget tests
flutter build apk --debug    # debug Android build
```
