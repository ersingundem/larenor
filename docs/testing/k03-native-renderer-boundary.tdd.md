# K03 native renderer boundary TDD evidence

This slice makes the Android side of the WebPanel renderer monitor match the
canonical Dart origin contract and keeps native failure details inside the
process. It introduces no wider WebView, file, network or JavaScript authority.

## Three accepted behaviors

1. The channel accepts only lowercase canonical `http`/`https` origin
   descriptors. DNS names use bounded ASCII labels; unbracketed IPv6 literals
   are parsed locally. Uppercase, encoded, bracketed, backslash and malformed
   host forms fail before a plugin WebView lookup.
2. A blocked subresource remains an empty 403 and now carries exact no-store,
   no-referrer, no-sniff and `default-src 'none'; sandbox` response policy.
   Request headers and bodies are never inspected or reflected.
3. Renderer termination is consumed once even when the local notification
   callback throws. Its private exception does not crash the Android WebView
   callback or reach Flutter.

## RED and GREEN

Commit `7e07d2e0c4b404103e64d07d8e0e9586b23dcef2` produced three focused test
failures for noncanonical channel origins, missing blocked-response policy and
an escaping renderer callback exception.

Commit `fb1d57140c7799a8faf4b856e5314ae9c2ff5b81` implements the strict parser,
empty-response headers and one-shot exception containment.

```text
./gradlew -p android :app:testDebugUnitTest --tests com.ersingundem.larenor.webpanel.WebPanelRendererBridgeTest
# BUILD SUCCESSFUL; 7 focused tests passed
```

K03 remains pending until its complete upload/download, pop-up/intent,
authentication/certificate, redirect/iframe and exact-head CI matrix is closed.
Progress remains 26/125 and 0/63.
