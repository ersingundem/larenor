# F60 — actual Linux owned-input observer probe, 3 October 2026

[Run 37130637087](https://github.com/ersingundem/larenor/actions/runs/37130637087)
completed successfully on exact
`a3f01b5fa888e4ef665cbfe842ae8a79a65e1696`. Root verified the named
`f60-owned-input-probe` job and its source-bound finite receipt. Other workflow
jobs were intentionally skipped by this narrow scope.

The hosted Ubuntu probe uses a fresh owned Xvfb display, the production
`Xi2PointerWitness` and real XTest pointer/button events. It proved listener
readiness and observed both events. Cleanup is bounded and an existing display
socket/lock is refused. The receipt explicitly sets `featureAccepted=false`
and `gate=owned_xi2_observer_only`.

Root independently extracted and validated the exact receipt keys, source and
booleans. Receipt SHA-256:
`ee6c8d69c30b207793416e0e24dd6a5e2fc218e5ae5d7aa0b8f74e9fca149cf9`.
Private captured job-log SHA-256:
`b9cf995af910fe4a1076c14ae6852b5211df917d082858640003f40688a49bae`.

This isolates the base XI2 observer. It does not explain or resolve the
integrated Sunshine phase bridge failure in
[run 37128656191](https://github.com/ersingundem/larenor/actions/runs/37128656191):
`touch_ready` ACK failed after first-frame/nonzero-audio checks and before
Android input dispatch. Source-bound phase-bridge failure observation and
actual two-lifetime stream/input/disconnect/close acceptance remain open.
F60 stays `reworking`; no accepted counter increases.
