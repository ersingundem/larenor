# Strict native acceptance at 57f92945

Both runs used exact source
`57f929459a22ab6082e400194e31e0162545f672` and completed unsuccessfully.
Neither feature is eligible for CI-waiting or completion status.

## F60

[Run 36819571890](https://github.com/ersingundem/larenor/actions/runs/36819571890)
contains the original named stream test: **1 test, 1 failure, 0 errors,
0 skips**. Its bounded diagnostic records `pairedClientObserved`, followed
by `firstStreamOutput` at owned test source line 223. This is later than
the previous PIN read boundary. The failing assertion expects the stream
command to return `native_observed`; the published diagnostic does not
establish its actual state or the provider's underlying reason. Pairing
progress is not frame/audio/input or full stream acceptance.

The active diagnostic artifact is `11143132368`. Root downloaded it into a
private directory and verified its source and named-test identity. Its JSON
SHA-256 is
`f1d9a316d902ced0b61968efbd3dd2c2393ded5b450d49daa458d58f6de61a65`.
Raw provider logs and credentials are not published.

## F62

[Run 36819574142](https://github.com/ersingundem/larenor/actions/runs/36819574142)
passed the arm64 package job. The x86 packaged-host job's original named
test reports **1 test, 1 failure, 0 errors, 0 skips**. It fails during
`initialFrameWait` with `RdpOwnedInitialFrameTerminalFailure`;
`serverResizeRequested=false`. This narrows the failure to a terminal
session observed before the initial frame completes. The receipt does not
contain the session failure code or a lifecycle marker, so it does not
prove the native cause or a resize failure.

The active diagnostic artifact is `11143432029`. Its source, counts,
exception class, and owned source frames were independently inspected.
Its JSON SHA-256 is
`d38249d6954ae418882125d77994c41e8e1f2c18b459230030430a024351d0aa`.

## Next boundary

Keep the original real frame/audio/input, TLS/NLA/SPKI, frame ACK, resize,
clipboard, two-lifetime, and cleanup acceptance gates. Establish the exact
remaining cause with bounded source-based diagnostics or a concrete
regression before running changed source again. Do not rerun the same
source or replace native evidence with compilation, synthetic frames,
relaxed assertions, or longer waits.

## Changed-source diagnostic gates

The exact `c9fee6d7ed83807af7917c89b26a7315966ce6cb` [F60 run 36822674910](https://github.com/ersingundem/larenor/actions/runs/36822674910) now binds fixed command-state enums to the original source/test/stage identity. Root59 runner/workflow checks and actual AndroidTest compilation278 tasks passed. It remains running; no terminal stream receipt is claimed.

The exact `5aa76fe85e522b2648b5957ebab5f47270af608d` [F62 run 36822994907](https://github.com/ersingundem/larenor/actions/runs/36822994907) adds a fixed initial-terminal classification captured from the same failed session tuple. Root44 runner/workflow checks and actual AndroidTest compilation277 tasks passed. Both ABI jobs remain running; no terminal runtime acceptance is claimed.

These changed-source gates preserve every original acceptance requirement. Neither compilation nor diagnostic-field coverage repairs or proves the old native failure by itself.
