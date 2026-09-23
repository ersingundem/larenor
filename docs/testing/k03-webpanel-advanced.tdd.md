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

Pending implementation and exact verification.

## Remaining acceptance

Physical tablet/DeX, OEM renderer behavior and trusted client-certificate
installation remain separate device/manual evidence. WebPanel keeps rejecting
HTTP auth, TLS bypass and client-certificate prompts; this slice does not add a
credential path.
