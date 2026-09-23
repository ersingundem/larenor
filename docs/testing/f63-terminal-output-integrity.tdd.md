# F63 terminal output integrity

## Boundary

SSH stdout and stderr remain passive text. They cannot invoke ANSI/OSC actions, links, clipboard writes, local commands, or automatic reconnects. This slice closes three display and memory boundaries before terminal text reaches the tablet UI.

- UTF-8 is decoded incrementally and strictly across packet boundaries. Malformed input closes the attempt as `connection_lost`; replacement text is not published.
- ESC stays visibly escaped and Unicode directional controls are replaced with `⟦bidi⟧`, so remote text cannot silently reorder host, command, or status content.
- Retained history is capped at 65,536 UTF-8 bytes. Tail selection walks Unicode scalar boundaries and never leaves a split surrogate.

## TDD evidence

- RED `363454b7`: malformed input remained connected, bidi controls remained active, and emoji history exceeded the byte budget.
- GREEN `efe7447e`: focused SSH controller tests pass 20/20 and focused Dart analysis is clean.
- Queue validation, per-commit progress, and diff checks are required before merge.

F63 remains pending for its other software slices and isolated real-host/Huawei/DeX acceptance.
