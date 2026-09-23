# K07 live TLS MQTT acknowledgement slice

Date: 2026-09-23

This slice replaces the last package-socket assumption in the paired-tablet
MQTT path with a real TLS socket test. The fixture creates a short-lived local
certificate at test time, accepts an MQTT 3.1.1 connection, verifies the
separate client id/username/password fields, acknowledges the command
subscription, receives retained telemetry, and sends a non-retained command
back to the Client. The generated key and certificate remain in the operating
system temporary directory and are deleted by test teardown.

## RED

The rejection scenario sent a valid MQTT `SUBACK` with failure QoS `0x80`.
`MqttClientLocalBroker.subscribe` returned success as soon as it wrote the
request, so the managed runtime could report itself ready even though it had
no command subscription.

## GREEN

`MqttClientLocalBroker` now owns bounded per-topic acknowledgement futures.
It completes only on the package's `onSubscribed` callback and fails closed on
broker rejection, timeout, disconnect, or a duplicate in-flight request. The
adapter still disables package logging, keeps credentials outside the broker
URL and leaves every reconnect decision to the authority-checking runtime.

Focused validation:

```text
flutter test test/features/kiosk_remote/mqtt_local_broker_live_test.dart \
  test/features/kiosk_remote/kiosk_remote_mqtt_runtime_test.dart
22/22 passed
```

K07 remains pending until its exact-head review and required CI evidence are
complete. This slice does not claim a physical broker, OEM background policy,
or tablet acceptance result.
