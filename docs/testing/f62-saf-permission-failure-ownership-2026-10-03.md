# SAF permission-failure ownership regression

The private-permission seam applies `0600` to a newly opened mirror part before its first payload byte. If that permission syscall fails, the helper closes the descriptor and attempts to delete the still-empty part. A filesystem may reject that best-effort deletion as well.

This regression models the bounded double failure by leaving an exact zero-byte part under `ToRemote` and throwing from `snapshotToRemote`. It exercises the production transfer coordinator and mirror manager rather than treating the helper as the owner. The manager has already created the complete private mirror ancestry and durably published the exact `PREPARING` transfer journal before the Documents adapter runs. Its failure path durably changes the same record to `UNKNOWN` before releasing the operation.

The regression verifies that:

- the public preparation fails with the closed `connectionFailed` code;
- the journal remains bound to the exact transfer and recorded mirror root in `UNKNOWN`;
- the empty part remains inside that recorded private mirror;
- no provider inspect, create, write, or readback method runs;
- the same process owner remains reserved and a successor preparation returns `busy`; and
- a cold coordinator preserves `UNKNOWN`, performs no provider effect, retains the part, and continues to reject a successor.

Current production code intentionally has no automatic `UNKNOWN` discard. `discardAfterClose` is not a public recovery path and the journal admits discard only from `SEALED` or `COMPLETE`. This regression therefore proves durable ownership and fail-closed successor fencing. It does not claim automatic cleanup, retry, provider I/O, or feature acceptance.
