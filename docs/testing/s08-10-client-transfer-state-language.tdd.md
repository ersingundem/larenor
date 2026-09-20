# S08.10 Client transfer evidence language

20 September 2026. This Android tablet slice closes three software criteria in the transfer status language:

1. a user-started request is shown as registered without implying that Core was reached;
2. a valid Core descriptor response and a completed provider receipt are retained as separate service and provider evidence;
3. provider acceptance is never promoted to overall success until Android SAF confirms the device save.

The evidence card now presents request, service, provider and device stages in English and Turkish. A descriptor or framed-transfer failure can retain service reachability without inventing provider acceptance. A cancelled or failed device picker can retain an authenticated Core receipt, while the card remains checking or action-required. Session, home, resource, ACL and lifecycle retirement still clear every stage together.

## TDD evidence

| Guarantee | Evidence | Result |
| --- | --- | --- |
| Missing staged evidence and false verified SAF-cancel state were specified first | `04c88645`; focused tests failed on missing controller evidence and the old verified card | RED |
| Request and service evidence are independent | A gated descriptor request records intent while service/provider/device remain unverified | PASS |
| Service and provider evidence are independent | Invalid framed bytes retain verified service reachability and no provider acceptance | PASS |
| Provider and device evidence are independent | SAF cancellation retains provider acceptance but exposes `Transfer incomplete` and `Device result: not saved` | PASS |
| Tablet semantics and layout regressions remain compatible | EN/TR, 600/1200 px, 2x text and lifecycle cases in the focused tablet suite | PASS |
| Owned source and tests are statically clean | Targeted `flutter analyze --no-pub` | PASS |

The combined focused Flutter run completed with **29 PASS** and zero skips. S08.10 remains open for the remaining protocol and physical Huawei/DeX/SAF/LAN acceptance. Queue progress remains 15/125 and selected feature progress remains 0/63.
