# PRODUCT.HEALTH software acceptance — 30 September 2026

The independently reviewed software boundary is read-only Health Connect and
explicitly mapped Home Assistant scale entities. It does not represent Huawei
or Apple provider approval, an available real account, or physical device proof.

The production route enters `WellbeingGate` and `WellbeingScreen`; Android
`MainActivity` composes `WellbeingBridge` with `HealthConnectBackend`.
The backend checks SDK availability and granted permissions, reads bounded
weight/body-fat records, and aggregates steps. Missing readings remain unknown.
It does not insert or delete health records. The HA adapter reads only an
explicitly selected entity. Permission approval never starts a query by itself.

The current route, foreground/private-view lease and account guard every read.
Revoke, late responses and account replacement clear measurements in memory;
measurements are not persisted. Corrupt privacy state fails closed across the
health screen, dashboard, search and ambient surfaces. Huawei remains explicitly
`providerRegistrationRequired`; direct Apple Health on Android remains
`unsupportedPlatform`, without invented provider authentication or data.

Named local gates:

```text
flutter test --no-pub test/features/wellbeing: 100 passed
flutter analyze lib/features/wellbeing: no issues
Android wellbeing: 21 passed, zero skips/failures/errors
  Bridge 8, Permission 2, PrivateView 3, Reader 8
independent production entry, read-only SDK and privacy/lifecycle review: passed
```

The SDK boundary was also checked against the official Android
[availability contract](https://developer.android.com/health-and-fitness/health-connect/availability)
and [read-data contract](https://developer.android.com/health-and-fitness/health-connect/read-data).
Health Connect availability depends on Android/API, Google Play services and
profile support. Cumulative steps use aggregation to avoid source double counting;
the implementation does not hardcode an on-device data-origin package.

`PRODUCT.HEALTH` can await exact-HEAD CI for this complete software boundary.
Physical Health Connect permission/provider behavior, GMS/OEM compatibility,
real scale measurements and Huawei/Apple provider approvals remain
`MANUAL.HEALTH`. They are not claimed by the local JVM/Flutter gates.
