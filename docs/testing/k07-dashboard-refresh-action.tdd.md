# K07 managed dashboard refresh action

Status: **bounded software slice ready; K07 stays pending**

## Three acceptance tasks

1. **Useful closed command.** A verified `refreshDashboard` MQTT command now
   invalidates and reloads the durable dashboard layout before publishing a
   success acknowledgement. The command surface remains closed; `syncProfile`,
   `lockKiosk` and unknown values return unsupported and perform no action.
2. **Exact session ownership.** The executor belongs to the exact native-source
   lease created only after secure enrollment, current Core authority, explicit
   TLS broker enablement and foreground binding. Account, Core, home, route,
   lifecycle or lease retirement wins before and after the refresh and returns
   denied instead of publishing stale success.
3. **Bounded failure behavior.** One lease runs at most one refresh at a time,
   waits at most ten seconds and converts action failures to a typed failed
   result. The existing MQTT sequence, digest, expiry, rate, replay and
   authority checks still run before the executor is reached.

## Evidence

- RED `d567d2c1` defined the missing action port, exact command allow-list,
  lifecycle race and bounded failure result before implementation.
- The focused native source, production dashboard action, MQTT runtime and
  runtime-owner package passes **42/42** tests.
- Scoped Flutter analysis, queue validation and `git diff --check` pass.

## Remaining K07 gates

K07 and both progress counters remain unchanged at **26/125 (20.8%)** and
**0/63 (0.0%)**. Managed profile synchronization needs a real versioned profile
contract. Kiosk locking needs verified Android managed-device authority. Live
broker deployment plus Huawei background/process-death and Samsung DeX,
keyboard and TalkBack hardware acceptance remain open.
