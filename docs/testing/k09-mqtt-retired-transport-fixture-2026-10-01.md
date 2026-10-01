# K09 MQTT retired-transport fixture evidence — 2026-10-01

## Failure classification

Linux Flutter shard 1 in run `36808321597`, job `110197544826`, failed the live TLS test `held CONNACK cannot install listeners or tear down its successor` with a late `SocketException: Broken pipe`. The stack originated from the MQTT TLS connect path while the test was tearing down its owned loopback sockets.

A focused local sequence reproduced the same class of failure before this repair: the existing unacknowledged-publish retirement test followed by the held-CONNACK and reset-retirement cases produced `Connection reset by peer` in `MqttServerSecureConnection.connect`. The successor assertions were still strict; no retry or transport error was accepted as success.

The production generation and client-identity checks were not the defect. The held-CONNACK fixture called `SecureSocket.destroy()` for every server connection during teardown. That reset could be delivered after the test body had completed and be attributed to the active Flutter test. The fixture now performs bounded, awaited TLS close and uses destructive close only when graceful close fails or times out.

## Regression

The focused suite retains the original held-CONNACK case and adds `retired transport reset is contained and cannot tear down its successor`. The new case deliberately resets only the retired first transport after a successor has authenticated, subscribed, and published. It then requires:

- the retired `connect` to finish as `mqtt_connect_retired`;
- the successor MQTT session to remain installed;
- the exact successor subscription and publish to be observed by the owned broker; and
- fixture teardown to finish without a late zone error.

This evidence covers owned loopback TLS/MQTT software behavior. It does not claim an external broker or physical network result.

## Focused result

`flutter test test/features/kiosk_remote/mqtt_local_broker_live_test.dart`

Result: 6 passed, 0 failed, 0 skipped. The full focused file was run twice after the repair.

Root independently ran the repaired MQTT suite with the source-label regression:
**7 passed, one explicit normal-Core-runner-only skip**. That skip is the separate
TCP integration gate; it does not substitute for an invoked runner. Focused
Dart analysis and exact no-write formatting checks passed. The label assertion
now expects the actual, intentionally qualified legacy provenance text
`Previously declared assistant source: Imported receipt`, matching the current
English localization. Production MQTT runtime is byte-identical to the prior
commit. The changed source requires fresh hosted Flutter shards; the failed
old run is not restarted.
