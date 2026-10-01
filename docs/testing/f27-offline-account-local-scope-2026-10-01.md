# F27: token-free local media scope

The account controller can expose the cached Core/home/account/session-family
identity after a retryable startup connection failure. This selector enables
only lookup of already verified encrypted media. It contains no endpoint,
access or refresh token, provider credential, or role. The cached session is
never adopted as an authenticated API session; `withSession` remains rejected.

The selector is unavailable during auth mutation, an unconfirmed refresh,
pending context binding, mandatory password change, logout, disposal, or
authoritative rejection. A late secure-store read cannot restore it after
logout. Profile activation and authentication replace its generation and scope.

Root verification on 2026-10-01:

- `flutter test test/features/server/server_account_local_media_scope_test.dart
  test/features/server/server_account_test.dart
  test/features/server/server_account_context_test.dart --reporter expanded`:
  **62 passed**, including **9 new local-scope cases**.
- Scoped Dart analysis of the scope, account controller, and new test:
  **no issues**.
- Private run log:
  `/private/tmp/larenor-local-media-account-root-20261001.log`.

This is a focused account-boundary result. F27 remains in development until
the real offline inventory/player navigation and complete acceptance gates
are verified. This result is neither broad CI nor physical-device evidence.
