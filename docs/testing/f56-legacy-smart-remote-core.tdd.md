# F56 legacy smart-remote Core acceptance

This package establishes a fail-closed Core boundary that can reuse an existing
Home Assistant remote provider or an isolated bridge without copying either
provider's state owner. The normal provider supports an explicitly bound Home
Assistant Broadlink `remote` entity and names already learned by Home
Assistant. Physical IR/RF hardware acceptance remains a separate manual gate.

Exactly three user acceptance criteria are in scope:

1. A command preview binds the exact Core, home, account, session family,
   device, bridge, provider, profile, code-set, and opaque binding revisions.
   Stored, reachable, and provider-verified states are separate, and any drift
   fails closed before a worker can run.
2. A command requires a short-lived preview and explicit confirmation. Exact
   delivery readback is idempotent; a missing or mismatched acknowledgement is
   uncertain and the same request is never replayed in-process. An emitted IR
   or RF receipt never claims that the appliance changed state.
3. Only profile-listed keys, repeat counts up to three, and hold durations up
   to two seconds can cross the worker boundary. Learning and raw IR/RF inputs
   are rejected, while provider signal bytes, credentials, and secrets are
   absent from every public profile, command, receipt, and result model.

## Normal Home Assistant provider

An administrator accepts a source by exact Home Assistant service revision,
Broadlink `remote.*` entity, explicit `ir` protocol, display name, learned
device name, and a bounded logical-key to learned-command-name map. The map is
encrypted at rest and raw codes are rejected, including every `b64:` command.
Registry verification requires one enabled `platform=broadlink` entity whose
config entry and device
agree with a Broadlink-manufactured device record. The provider rechecks that
sealed provenance, source revision, service revision and authenticated
verification state, current administrator/session authority, and the entity's
live `on` state before the network write and again afterwards.

The Flutter setup flow lists only currently authenticated Home Assistant
service records. It sends the closed source model and causally reads the stored
record back before reporting success. The read projection contains an opaque
HMAC configuration tag, logical keys and public entity identity; learned
device/command names, raw codes and credentials remain private. The Home
Assistant device view does not offer learning because this provider cannot
prove that Home Assistant committed a newly learned name.

The fixed effect is only `POST /api/services/remote/send_command`, with one
entity ID, one stored device/command name, a maximum of three repeats, fixed
0.4-second delay and zero hold time. Generic Home Assistant action payloads,
base64 signal material, arbitrary domains, ZHA cluster commands and shell
commands cannot cross this boundary.

Home Assistant's Broadlink implementation catches transport exceptions while
sending and can return from the action without proving that any packet was
emitted. Therefore even HTTP 200 plus a still-live remote state produces the
durable `uncertain/lost_ack` result. Core persists `attempted=true` before the
POST and never sends that request ID again, including after restart. The normal
provider does not expose learning because Home Assistant has no bounded public
readback proving the learned name was committed. ZHA is also excluded because
its official API does not expose the same generic learned IR/RF name contract.
The `ir` label is an explicit operator declaration: Home Assistant's public
send action does not reveal the stored packet type, so physical IR acceptance
remains a manual evidence gate.

Primary-source evidence:

- [Home Assistant remote send-command action](https://www.home-assistant.io/actions/remote.send_command/)
  defines the entity target, learned device/command name, repeat, delay and hold
  fields used by the fixed request.
- [Home Assistant Broadlink integration](https://www.home-assistant.io/integrations/broadlink/)
  defines learned IR/RF command storage and `remote.send_command`, including
  the separate raw `b64:` form which this provider rejects.
- [Home Assistant Broadlink remote source](https://github.com/home-assistant/core/blob/dev/homeassistant/components/broadlink/remote.py)
  shows hardware send exceptions are logged and swallowed inside the command
  loop, so HTTP service completion is not a packet acknowledgement.
- [Home Assistant Infrared integration](https://www.home-assistant.io/integrations/infrared/)
  distinguishes IR adapter entities and device-specific integrations from the
  Broadlink learned-command workflow used here.

## TDD evidence

The RED commit `e7d2af3a` failed collection because the
`larenor_server.legacy_remote` package did not exist. The focused matrix covers
nested revision drift, deadline and delivery idempotency, lost acknowledgement
without replay, permission and command bounds, public-model field inspection,
secret redaction, HMAC audit tamper rejection, authenticated Broadlink registry
provenance, raw-code rejection, exact loopback HTTP serialization, service
retirement, and restart recovery with exactly one POST.
