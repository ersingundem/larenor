# B5.1 Daily, detail and widget actions

The journeys were derived from the B5.1 tablet acceptance queue and verified with Flutter widget tests before the production changes.

## Acceptance criteria

1. **Today actions:** On English and Turkish 600/1200-wide tablet or DeX windows at 2x text, refresh, list, add and completion actions expose 48dp keyboard-reachable TalkBack buttons; a retained callback cannot refresh after its route is covered.
2. **Media title request:** A TV title request opens its real season chooser from Enter, keeps request/cancel controls as 48dp TalkBack buttons across the same locale and viewport matrix, and rejects a retained request callback from a covered route.
3. **Direct Keenetic widget picker:** Add, internet-status and WAN-traffic choices remain 48dp keyboard-reachable TalkBack actions in the same matrix, return the selected local widget draft, and reject a retained metric callback after route authority is lost.

## RED/GREEN evidence

| Stage | Command | Result |
| --- | --- | --- |
| RED | `flutter test test/features/today/today_screen_test.dart test/features/keenetic/keenetic_metric_ui_test.dart test/features/media/hub/media_title_detail_tablet_actions_test.dart` | Failed on 44dp targets, merged semantics, and all three covered-route callbacks. |
| GREEN | Same targeted command | 58 tests passed. |

The suite covers real navigation/action results, route visibility, account/session generation guards, EN/TR localization, 600/1200 widths, 2x text, Enter activation and TalkBack semantics. Queue and feature counters remain unchanged because B5.1 closes only after its remaining acceptance gates.
