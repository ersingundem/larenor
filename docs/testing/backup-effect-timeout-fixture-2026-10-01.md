# Backup effect timeout fixture evidence (2026-10-01)

## Boundary

The component-backup production deadlines and reconciliation rules are unchanged. This repair only keeps the owned Unix Engine fixture listening while the production adapter runs its final authority check between `GET /version` and an effect request.

The fixture has two independent waits:

- the server wait for the guarded second request on the already verified stream; and
- the deliberate 1.5-second delay after applying the pause or unpause effect, which forces the client into its existing ambiguous-response reconciliation path.

The first wait now follows the explicit test operation bound: 11 seconds in the focused adapter test and 30 seconds in the power-loss recovery fixture. The client effect idle budget remains one second. The delayed response, fresh `GET` readback, exactly one pause POST, exactly one unpause POST, and no replay assertions remain intact.

## Deterministic gate coverage

The focused adapter test holds the final pause authority revalidation for 1.1 seconds after `GET /version`. The previous one-second fixture wait closed that verified stream before the authorized POST. With the fixture wait separated from the response delay, the same stream carries exactly one POST, the response remains deliberately ambiguous to the client, and a fresh read observes the applied state without replay.

## Hosted failure interpretation

Run `36816909489` reported `component_engine_unavailable` for the timeout reconciliation test, and its bounded traceback reached the fresh-state check with `paused=False`. Because the fixture sets `paused=True` before delaying the response, a POST that the fixture handled would have made that read true. This is strong source-backed evidence that the POST was not handled, but the hosted wrapper did not retain the inner transport exception, so it is not an exclusive proof of the old run's cause.

The power-loss staging failure was wrapped as `component_restore_unavailable`; its inner cause was not retained. Its two-second fixture wait had the same source-level mismatch with the already explicit 30-second operation bound. The alignment is therefore a justified fixture repair, not a claim that the opaque hosted failure had one proven cause.

Hosted Linux acceptance of the changed source remains required.

The old one-second owned server variant failed the delayed final-gate case.
The repaired two exact hosted failure nodes passed independently under root
(2/2). Both affected modules passed the agent's full focused gate with 35
passes and one explicit platform skip. No production timeout or reconciliation
rule was changed.
