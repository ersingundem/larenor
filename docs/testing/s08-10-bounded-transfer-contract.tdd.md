# S08.10 bounded transfer shared-contract TDD evidence

## Acceptance slice

This slice closes three software-only integration criteria from
`docs/s08-10-integration-acceptance-2026-09-15.md` on 20 September 2026:

1. product upload and descriptor fields are captured from authenticated Core
   HTTP and consumed unchanged by the Android Client;
2. the exact framed download bytes, metadata, completion receipt, and retained
   history authenticate one another across Server and Client; and
3. stale revisions and unsupported ranges remain fixed, content-free failures
   and do not create extra retained history.

The versioned `contracts/bounded-transfer.v1.json` artifact contains only a
synthetic payload and public response metadata. Access and refresh tokens are
explicitly excluded by the Server generator.

## RED and GREEN

| Stage | Commit or command | Result | Guarantee |
| --- | --- | --- | --- |
| RED | `59f1b8ea`; focused Server pytest | 2 expected failures because the shared versioned fixture did not exist. | Server-side contract generation was executable before adding the artifact. |
| RED | `59f1b8ea`; focused Flutter test after repository code generation | 3 expected missing-fixture failures. | Android consumed the same absent artifact rather than a handwritten duplicate. |
| GREEN | `a9ce5e86`; bounded transfer/product/receipt Server group | 45 passed. | Actual authenticated HTTP still matches the fixture and existing authority, persistence, and framing behavior. |
| GREEN | `a9ce5e86`; `flutter test --no-pub test/features/home_resources/bounded_transfer_contract_test.dart` | 3 passed. | Upload, descriptor, framed download, proof/history, and closed errors share one Core-generated contract. |
| Static | `python3 -m compileall -q server/tests/test_bounded_transfer_contract.py` and focused Flutter analyze | Passed. | The owned test surfaces compile and analyze cleanly. |

## Scope boundary

This is the shared contract evidence required by S08.10's integration gate. It
does not replace pending transfer-event checkpoint integration, physical
Huawei/DeX/SAF acceptance, or exact-main CI. Queue and selected-feature
counters therefore remain `15/125` and `0/63`.
