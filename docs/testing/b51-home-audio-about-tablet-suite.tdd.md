# B5.1 home, audio, and About tablet acceptance

## Scope

This independent B5.1 slice reviews three existing product surfaces against
Apple HIG layout, hierarchy, focus, and accessibility principles while keeping
Larenor's Android tablet conventions. The software evidence targets Huawei
MatePad class windows and resizable DeX windows. Physical device and TalkBack
acceptance remain separate from this local widget-test evidence.

## Three acceptance criteria

| Criterion | Accepted behavior | Evidence |
| --- | --- | --- |
| About actions | The pane uses the shared settings hierarchy. Legal and sign-out actions expose native button semantics and at least 48 dp targets. Enter opens the real legal route. Sign-out keeps its auto-dispose provider alive, rejects callbacks captured before an interaction-epoch change, is single-flight, and navigates only while its originating route and authority are current. | EN/TR, 600/1200 px, 200% text matrix plus the real router/provider sign-out test in `about_pane_tablet_accessibility_test.dart` |
| Local audio | Source, playback, artwork, and power actions share the service/settings visual language. Enter starts the real bridge action. Every rendered callback captures the active interaction identity and epoch; an idle/wake cycle cannot revive play, seek, transport, picker, format, artwork, or navigation authority. A picker result from an expired epoch is discarded before native decoding. | EN/TR, 600/1200 px, 200% text matrix in `local_audio_ui_test.dart`; lifecycle/artwork regressions in `local_audio_artwork_ui_test.dart` |
| Room-to-area sync | Status, area selection, preview, apply, refresh, and unbind use the shared tablet sections and real providers. Preview has a 48 dp named button with TalkBack semantics and Enter activation. Existing generation, account, source, modal, background, and stale-preview guards continue to reject expired writes. | EN/TR, 600/1200 px, 200% text matrix and source/account/background adversarial cases in `dashboard_edit_ui_test.dart` |

## RED to GREEN evidence

- Artwork authority RED: the expired OS-picker result rendered a draft and
  called native preparation; the focused test failed with one unexpected
  `local-audio-draft-cover`. GREEN captures the epoch before the picker and
  rejects the bytes before decode.
- Local-audio callback RED: invoking a play callback captured before idle/wake
  started one source. GREEN rebuilds from `AppInteractionScope` and validates
  the captured controller and epoch for every interactive callback.
- About action RED: an expired sign-out callback cleared the provider and also
  exposed an `UnmountedRefException` while the auto-dispose notifier was not
  watched. GREEN keeps the notifier alive, rejects expired Legal/sign-out
  callbacks, and collapses duplicate sign-out activation into one operation.
- Final focused command covering all three criteria passed **73/73** tests:
  `flutter test test/features/settings/about_pane_tablet_accessibility_test.dart test/features/media/local_audio/local_audio_ui_test.dart test/features/media/local_audio/local_audio_artwork_ui_test.dart test/features/dashboard/dashboard_edit_ui_test.dart`.
- The same focused suite with `--coverage` recorded **563/595 lines
  (94.6%)** across the three owned screens: About 55/55 (100%), local audio
  308/323 (95.4%), and room sync 200/217 (92.2%). `flutter analyze` completed
  with no issues after regenerating the existing localization output.

## Boundaries

The tests use local fakes and provider overrides. They do not contact Home
Assistant, media services, or an external account. This slice does not claim
physical Huawei/DeX/TalkBack acceptance or close the remaining app-wide B5.1
visual pass. Queue progress therefore remains **17/125**.
