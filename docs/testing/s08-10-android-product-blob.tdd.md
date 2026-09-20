# S08.10 Android product blob TDD evidence

## Accepted journey

A write-authorized tablet user can explicitly select a document or small media
file, store it through the separate Core binary boundary, and later download the
current replacement through the verified framed transfer. Read-only accounts do
not receive the upload action. No picker path, token, content byte, or private
error body is placed in UI state or diagnostics.

## RED and GREEN

| Stage | Command | Result | Guarantee |
| --- | --- | --- | --- |
| RED | `flutter test test/features/home_resources/core_bounded_product_blob_test.dart` | Expected compile failure: descriptor, upload and bounded picker types did not exist. | The test names the missing public Client behavior before implementation. |
| GREEN | `flutter test --coverage test/features/home_resources/bounded_download_test.dart test/features/home_resources/core_bounded_product_blob_test.dart test/features/home_resources/core_bounded_download_controller_test.dart test/features/home_resources/home_resources_tablet_test.dart` | 49 passed. | Closed descriptor/upload parsing, exact authority headers, revision-driven download, receipt verification, picker bounds, lifecycle retirement and tablet UI pass together. |
| Coverage | The GREEN command's `coverage/lcov.info` | API 93.5%, picker 80.6%, controller 86.3% line coverage. | New non-UI production boundaries meet the slice coverage floor. |
| Tablet | Same GREEN command | EN/TR, 600/1200 logical pixels, 2x text, at least 48 px action target and semantics status passed. | The upload journey remains usable on compact tablets and desktop-width Android windows. |

## Remaining boundary

This slice does not claim physical Huawei/DeX SAF or real-LAN evidence. It does
not add range/resume, larger media protocols, or complete S08.10 event
checkpoint convergence. The execution queue and selected-feature counters stay
unchanged until those independent acceptance requirements and exact-main CI are
complete.
