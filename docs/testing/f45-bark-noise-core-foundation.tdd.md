# F45 bark and noise event Core foundation

This independent slice defines the privacy and authority boundary between a local sound classifier and future Larenor automation rules. It is metadata-only and does not register a public route or accept raw audio.

## Acceptance criteria

1. **Consent-bound digest evidence.** Closed models reject raw audio and unknown fields. Every observation is bound to the exact Core, home, room, device, model, provider, policy and consent revisions. Consent must be current and granted; retained events contain only bounded classification metadata and a SHA-256 evidence digest, and expire at the configured one-minute to seven-day retention boundary.
2. **Stable local detection.** Confidence thresholds use a bounded consecutive-sample trigger, lower release threshold and exact-binding hysteresis. Active detections and events inside the configured deduplication window are suppressed idempotently, while unavailable classifiers report an explicit degraded provider state without invoking automation.
3. **Verified automation handoff.** Every decision is chained in a bounded HMAC audit. Automation receives a sanitized immutable trigger and is considered successful only when its receipt exactly reads back the event, scope, room/device/model/provider/policy/consent revisions and audit checkpoint. Missing, foreign, stale or malformed receipts remain degraded, and audit tampering blocks later processing before another handoff.

## TDD evidence and remaining gates

- RED: `cd server && uv run pytest -q tests/test_f45_bark_noise_events.py` failed during collection because the sound-event module did not exist.
- GREEN: the same focused pytest target passes all three acceptance tests, including parameterized revision drift, retention expiry, hysteresis, deduplication, provider degradation, receipt mismatch and audit tampering.
- Queue progress remains **21/125 (16.8%)** and selected-feature progress remains **0/63 (0.0%)**. F45 stays open until a packaged local classifier, persistent Core repository, automation UI, Android notification flow and physical-device evidence are verified.
