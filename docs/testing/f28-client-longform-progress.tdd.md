# F28 Client longform progress slice

This slice adds the first read-only F28 Client path for unfinished audiobooks
and podcast episodes. It intentionally keeps F28 pending and preserves queue
progress at **26/125** and selected-feature progress at **0/63**.

## Three acceptance jobs

1. The Dart response model accepts only the exact `longform` schema, at most 25
   unfinished items, the two declared media types, finite bounded positions,
   ordered chapters, and provider media identifiers without user info, query,
   fragment, HTTP URL, or control characters. Debug descriptions and visible
   semantics do not include media URIs.
2. The Core request sends only request, installation, Core, manager revision,
   and limit authority. Route callbacks fail closed when false or throwing.
   Account, session, route, manager, and longform-generation changes after an
   await retire the result; a reverify cannot be overwritten by the older
   request.
3. The Media management screen reads longform progress after manager
   verification and presents progress, duration, and current chapter in an
   English/Turkish card. Data, empty, and error/retry states fit 600 and 1280
   logical-pixel tablets at 200% text and expose bounded TalkBack semantics.

## RED / GREEN evidence

The RED batch failed at compile time because `ServerMusicLongformCatalog`,
`ServerMusicManagerApi.inProgress`, controller ownership, and
`ServerMusicLongformCard` did not exist. The GREEN batch covers strict parsing,
URL/secret rejection, exact request fields, throwing callbacks, route/account
retirement, overlapping reverify, localized accessibility layouts, explicit
empty/error states, and the production Media screen wiring.

Independent exact-head audit RED `2f4d6007` exposed contract drift from the
matching Core slice: non-contiguous chapter positions and safe provider URI
schemes were rejected, while overlong durations, a chapter starting exactly at
duration and overlapping chapter ranges were accepted. GREEN `2f2f2ee9`
aligns URI, numeric and timeline validation with Core. The expanded focused
batch passes **41/41** with targeted analysis clean.

Verification commands:

```text
flutter test test/features/server/server_music_longform_models_test.dart test/features/server/server_music_longform_api_lifecycle_test.dart test/features/server/server_music_longform_card_test.dart test/features/server/server_music_manager_controller_test.dart test/features/server/server_music_manager_api_authority_test.dart test/features/server/server_music_manager_screen_test.dart
flutter analyze lib/features/server/music_manager test/features/server/server_music_longform_models_test.dart test/features/server/server_music_longform_api_lifecycle_test.dart test/features/server/server_music_longform_card_test.dart test/features/server/server_music_manager_controller_test.dart test/features/server/server_music_manager_api_authority_test.dart test/features/server/server_music_manager_screen_test.dart
python3 tool/check_security_policy.py
python3 tool/execution_queue.py validate
git diff --check
```

F28 remains open for bookmarks, sleep timer, cross-session conflict behavior,
MediaSession/background continuation, explicit provider/format coverage, the
real Client-to-isolated-Core/service E2E, exact-head CI, independent review,
and applicable physical-device evidence. No progress file or queue state is
changed by this partial slice.
