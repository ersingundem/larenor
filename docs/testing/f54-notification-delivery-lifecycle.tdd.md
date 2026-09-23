# F54 notification delivery lifecycle hardening

This slice closes three Core-side lifecycle boundaries in the existing local
notification inbox. It does not claim background Android delivery or close
F54; queue progress remains **26/125** and selected-feature progress remains
**0/63**.

## Three acceptance jobs

1. An expired subscription is terminal. Its old revision cannot extend the
   expiry or reactivate delivery; the update fails with
   `notification_subscription_inactive` and leaves the stored revision and
   expiry unchanged.
2. A delivery already owned by an expired or revoked subscription is not
   replayed into a replacement subscription. The replacement creates no new
   acknowledgement row for that retired delivery.
3. A repeated pull for one active subscription reuses the same event ID and
   sequence receipt identity, and keeps exactly one delivery record with its
   original timestamp. The service now excludes known receipt identities from
   the insert batch instead of attempting a second delivery write. Existing
   Client and native reconciliation already deduplicate that stable pair.

The requested authority-change-during-await case does not exist in this
module: API handlers and service methods are synchronous, and each operation
does `assert_current` inside one `BEGIN IMMEDIATE` transaction before it can
publish a result. The first job therefore covers the nearest real fail-closed
lifecycle gap instead of adding a synthetic asynchronous path.

## RED to GREEN evidence

The focused RED run produced four expected failures: expired update returned
200, while revoked and expired replacement subscriptions each received the
retired event. The third regression records the existing stable event receipt
and proves the hardened service performs no second delivery write. After the
production change, the new lifecycle suite and the existing local-notification
regression suite pass together.

```text
uv run --project server --locked --no-sync python -m pytest -q \
  server/tests/test_f54_local_notification_delivery_lifecycle.py \
  server/tests/test_local_notifications.py
flutter test test/features/local_notifications/local_notification_core_e2e_test.dart
```

The focused Server batch passes **11/11** and the real loopback Client/Core
batch passes **8/8**, including bounded foreground reconciliation, authority
retirement and duplicate-identity rejection.

The receipt identity contains no credential or plaintext payload. Event
payloads remain AEAD-encrypted, and private lock-screen projection remains
redacted. F54 still depends on its Android background delivery, permission,
reconnect, OEM/Huawei power and physical-device acceptance gates.
