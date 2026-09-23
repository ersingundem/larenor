# K03 advanced WebPanel boundaries

Date: 2026-09-23
Base: `7d9bee7cbf15bb4685a530721e48dd5af0cff140`

This slice keeps `K03.remaining` pending and the counters at 26/125 and 0/63.
It closes three reviewable software boundaries without creating an iOS surface:

1. A download must match a declared byte length and the platform save result
   must be a bounded, query-free Android SAF `content://` grant.
2. Pop-up and external-app handling must fail closed when its current
   route/account authority callback throws, before Android launch.
3. A dead Android renderer must retire its WebView resources exactly once;
   cleanup failure must not suppress the generation-bound recovery callback.

## RED

- Flutter command:
  `flutter test test/features/web_panel/web_panel_transfers_test.dart test/features/web_panel/web_panel_external_actions_test.dart`
  executed 16 tests and failed on the intended SAF length/result and throwing
  authority cases.
- Android command:
  `/Users/ersingundem/oikos/android/gradlew -p android :app:testDebugUnitTest --tests com.ersingundem.larenor.webpanel.WebPanelRendererBridgeTest`
  reached the new test and failed to compile because the production
  `retireRenderer` contract did not exist.

## GREEN

- GREEN `de1ae3fc845ddee51e229e0951c13351da658408` requires exact
  `Content-Length`, accepts only a bounded query-free SAF content result,
  contains authority callback failures before external launch, and retires a
  dead Android WebView once before the recovery callback.
- The focused Flutter batch passed **62/62**, including EN/TR 600/1200 tablet
  layouts at 2x text, route/account/background retirement, origin policy,
  transfers, external actions and renderer generations.
- `WebPanelRendererBridgeTest` passed **8/8** under Robolectric, including
  one-shot renderer resource retirement and cleanup-failure containment.
- The grouped `test/features/web_panel` batch passed **113/113** and targeted
  analysis reported no issues. Repository security policy, queue validation,
  per-commit progress and secret scanning passed; diff checks run again on the
  final exact head.

## Remaining acceptance

Physical tablet/DeX, OEM renderer behavior and trusted client-certificate
installation remain separate device/manual evidence. WebPanel keeps rejecting
HTTP auth, TLS bypass and client-certificate prompts; this slice does not add a
credential path.
