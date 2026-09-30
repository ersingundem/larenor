# F05 normal Core home-workflow acceptance (2026-09-30)

`server/tests/support/f05_flutter_acceptance.py` is the named combined F05
production-path gate. It starts an owned Home Assistant HTTP fixture, a normal
Core and a real Flutter Client process. The Client creates a workflow through
`HomeWorkflowAccountApi`, explicitly approves its effect, and requires causal
Home Assistant readback before the workflow becomes completed.

The runner then restarts normal Core on the same database and starts a fresh
Flutter process. The Client reads the retained terminal workflow, replays the
exact create and approval identifiers to reconcile a possible lost response,
and creates then cancels a second workflow before provider dispatch. The owned
provider must receive exactly one POST across both Core lifetimes.

Run it with:

```sh
server/.venv/bin/python server/tests/support/f05_flutter_acceptance.py
```

The gate uses only synthetic credentials and an owned loopback provider. It
does not contact or mutate a household Home Assistant instance. Focused Server
tests separately cover process loss, unknown physical outcomes, human
reconciliation, timeout, cancellation during dispatch, authority drift,
storage tampering and record limits. Real household partial execution remains
a manual acceptance condition.
