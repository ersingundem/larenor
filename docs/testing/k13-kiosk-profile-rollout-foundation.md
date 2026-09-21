# K13 — kiosk profile rollout foundation

This slice previews a signed, versioned profile against a published Client
release and the existing Core tablet-fleet records. It is deliberately
read-only: the endpoint does not publish the profile, issue a fleet command,
install an APK or assert Device Owner provisioning.

## Three acceptance criteria

1. **Exact release and bounded profile.** An admin requests a canonical
   digest-bound dry-run with a profile revision, fullscreen/idle settings,
   stable/beta channel, 1–100% canary and at most 256 ordered device targets.
   Core reads a release from its already verified release store, validates the
   exact package, pinned certificate, version and APK digest, and HMAC-seals
   the profile identity. Invalid or absent releases fail closed.
2. **Authority and deterministic diff.** Every target is bound to its exact
   Core/home, authenticated admin session, device revision and current profile
   revision. A replay with changed fields, stale revision, revoked device,
   foreign account or wrong home cannot become ready. A stable cohort reports
   current, ready, deferred or app-update-required with explicit version and
   profile differences. The same request yields the same preview without a
   database mutation or command.
3. **Tablet admin summary.** Settings exposes a 10% dry-run in the existing
   tablet-fleet screen. It displays the verified release identity and rollout
   counts in EN/TR at 600/1280 widths and 200% text. The 48dp action supports
   keyboard Enter and TalkBack; lifecycle/account/route expiry and lost or
   malformed Core readback retire the summary rather than showing stale
   readiness.

## Evidence and remaining gate

`Server/tests/test_k13_kiosk_profile_rollout.py` covers read-only replay,
signature/pinning, scope/role/revision conflicts and deterministic cohorts.
The runtime binding also opens the exact published APK for bounded digest
readback before reporting rollout readiness. A missing/tampered APK or a
manifest change between latest-pointer and artifact read fails closed; the
stream is closed on both success and mismatch. This closes the post-startup
manifest-only readiness gap without changing the read-only dry-run contract.
The focused Flutter fleet API, controller and widget tests cover exact
request/response authority, stale callbacks, EN/TR tablet size, semantics and
keyboard action. Actual profile publication/restore, Android package manager
certificate readback, staged installation, Device Owner-only silent install,
OEM/physical acceptance and backup recovery remain separate K13 gates. This
slice cannot close K13 in the execution queue.
