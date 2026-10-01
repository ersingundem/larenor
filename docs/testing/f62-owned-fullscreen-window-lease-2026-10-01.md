# F62 transient fullscreen window owner — 1 October 2026

The existing Activity `WindowPolicyController` remains the sole owner of system
bar requests. A new acquire/release/cancel protocol gives one caller a unique
nonce, monotonically increasing revision and exact logical display incarnation.
It does not persist or change the user's adaptive/panel preference, enter lock
task, alter global settings, or allow a stale release to restore bars over a
replacement owner.

Acquisition requires a resumed, focused, known internal display with matching
identity and without multi-window, PiP, desktop caption or visible keyboard.
Foreground/display/observer loss retires the transient owner; resuming does not
recreate it. A later explicit profile change cancels it. Keyboard appearance
temporarily restores bars through the existing policy; the existing settling
callback re-evaluates the current owner. Duplicate acquisition does not re-hide
bars after a user swipe. Native application failure returns no usable lease.

The Flutter bridge parses a closed receipt and checks the same display and
foreground conditions. An unreadable grant can cancel only its fresh request
nonce. An accepted request is not evidence that bars are hidden: snapshots keep
the actual observed visibility, original requested profile and lock-task state.
The later RDP fullscreen UI must release on exit, stale route/session/account
and teardown, and prove its larger viewport and actual policy observations.
This foundation alone does not close the F62 fullscreen or native-host gate.

The initial required-mode packaged JVM run passed **21 tests** (8 new owner,
10 policy, 3 bridge). Independent review then found a real observation edge:
a readonly snapshot could notice display drift without retiring ownership and
allow the owner to revive. Snapshot now retires using that single observation,
without writing system UI, and acquisition rechecks ownership after its final
snapshot. Two regression tests cover drift and focus loss during acquisition.

The latest policy source passed **20/20 pure Kotlin 2.4.20/JUnit tests** (10 owner
and 10 policy), using the cached compiler independently of the pending schema 2
RDP package mount. The unchanged native bridge wiring had passed the initial
three packaged bridge tests. Root's Flutter bridge/policy/guard run passed
**15/15**, scoped analysis was clean, and two independent rereviews found no
remaining blocker. Physical DeX, Android bar visibility and RDP route integration
remain separate acceptance gates; this is not packaged schema 2 acceptance.

The design keeps an explicit exit available, preserves system edge-swipe access
and uses the same window API owner. Sources: [Android immersive mode](https://developer.android.com/develop/ui/views/layout/immersive)
and [Apple full screen guidance](https://developer.apple.com/design/human-interface-guidelines/going-full-screen).
