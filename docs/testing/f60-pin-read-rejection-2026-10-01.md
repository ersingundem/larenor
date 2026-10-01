# F60 owned PIN transport rejection — 1 October 2026

Exact `31f152c20cea3fde5b58b84b781be45564e90a54`,
[run 36816571516](https://github.com/ersingundem/larenor/actions/runs/36816571516),
failed. Root downloaded and read the bounded failure artifact privately.
Its SHA-256 is
`6c69d2dc254c90acea33c37ea20516d195ccbd5ef722c67116a3b0e43c9c3e66`.
The diagnostic is `instrumentation_report_missing` with fixed
`pinBridgeStage=readRejected`, no owned frames, and no runtime acceptance.

The new stage proves that the bridge accepted a connection, verified its
loopback peer, then rejected the bounded read before parsing the canonical
nonce/PIN message. It does not distinguish EOF, deadline, socket failure or
framing rejection. The host stops its exact Gradle child after a terminal
bridge error; the absent instrumentation XML does not prove an Android crash.

F60 remains `reworking`. Real frame/PCM/input, two fresh stream lifetimes and
clean retirement are still required. The same source is not blindly rerun.
