# F62 private schema-6 transfer and Gateway integration

Prepared from shared snapshot `0cadbbb42644e8f298bb7ff011d269cbd9229fbf`
on 2026-10-03. This remains a private integration overlay. None of these Dart
files have been copied into the workspace and the native schema-6 endpoints
are not yet part of the shared product.

## Frozen wire boundary

- Existing capabilities and ordinary open/input/resize/frame ACK/audio/
  microphone/cancel stay schema 4. Only `openOwned` and every operation on
  that exact owned channel use schema 6.
- Owned activation is exact `{schemaVersion:6,requestId}`. The open root is
  exact `{schemaVersion,request,requestId,password,gatewayPassword}`, with
  root `requestId == request.requestId`. Its request adds the positive JS-safe
  `sessionRevision` and `fileTransfer:{transferId:<32 lowerhex>}`. The planned
  UUID/revision are chosen before mirror preparation and never alias the
  process-private native owner token.
- `prepareFileTransfer` takes exact
  `{schemaVersion:6,requestId,authority,grantId,grantRevision,
  sessionRequestId,sessionRevision}`. `fileTransferObservation`,
  `drainFileTransfer`, and `saveReceivedFiles` add `transferId`.
- Every transfer reply is the exact seven-key
  `{schemaVersion,requestId,authorityId,grantId,grantRevision,transferId,state}`.
  Prepare accepts only `prepared`; observation accepts the closed lifecycle;
  drain accepts only `sealed|unknown`; Save accepts only `saved|unknown`.
  Unknown is sticky and blocks a successor. No transfer retry, discard, or
  synthetic drain is added.
- Transport `cancel` remains transport-only. It never seals a mirror. A
  confirmed drain seals the private mirror, and explicit Save Received is the
  sole SAF publication path.
- Gateway and target pins and password buffers remain distinct. The Gateway
  password is resolved from a device-only current secret just in time and both
  caller buffers are wiped after open. Core receives no password or secret
  reference.

## Prepared composition

- The Core profile decoder accepts the legacy exact seven-key profile or the
  exact eight-key form with nullable `rdp`. The RDP projection is closed
  `{domain,certificateFingerprint,gateway}`; non-RDP profiles cannot carry it.
  Ordinary profile updates preserve and read back that exact projection.
- RDP profile settings version 4 adds only public Gateway domain. Versions 1-3
  migrate without inventing a domain, pin, secret, or capability.
- The normal RDP panel now constructs the transfer coordinator and session
  authority only for an exact active grant. It uses one planned UUID/revision
  for microphone consent, mirror preparation, owned open, and retirement.
  A prepared grant cannot enable files while packaged capabilities report
  `files=false`.
- The MethodChannel engine retains schema 4 for ordinary sessions and stores
  the selected version per channel. Owned frames, input, resize, ACK, audio,
  microphone, activation, and cancellation all remain on schema 6 without
  affecting an ordinary channel.
- Session completion starts one exact drain. A sealed session exposes an
  explicit Save Received action. Unknown exposes read-only status recovery,
  remains blocked, and is never replayed. Reconnect cannot adopt an old
  prepared, sealed, saved, or unknown transfer identity.
- A separate device-only Gateway secret pointer is scoped by namespace,
  profile and revision. Rotation publishes and reads back the new pointer
  before deleting the old value. Live Core Gateway open resolves it at the
  last responsible moment; target credentials remain in their existing vault.

## Evidence

Private isolated Flutter gate:

- 9 focused files, **108 passed**, zero failures or skips.
- Includes legacy schema-4 MethodChannel behavior, owned schema-6 exact wire,
  original byte-buffer wiping, planned-owner open/drain, late prepare fencing,
  sticky unknown, explicit Save, Core projection preservation, profile
  migration, normal panel lifecycle, and files=false refusal.
- Scoped analysis of the exact 23 Dart overlay files: **no issues**.
- Test log: `focused-tests-final-2.log`, SHA-256
  `5f9566d58ee6f55b5481dee14362daa082068f775923fe0180653661e639e211`.
- Analyze log: `scoped-analyze-final.log`, SHA-256
  `facdcb54658a2494bac6cda5a81a5cadb933324895c3d17354fab3d5c0af7853`.

Root's separate latest native stage-2 gate reported **14/14** focused journal,
manager and recovery tests, with no failures, errors or skips. That evidence
proves the private Kotlin manager/recovery slice only; it does not prove the
MethodChannel composition or an actual SAF/RDPDR/Gateway effect.

## Remaining acceptance gaps

1. The four Kotlin transfer endpoints and mixed schema-4/schema-6 channel
   parser are not yet in the shared product or compiled with this Dart overlay.
2. Normal two-stage Gateway enrollment has no user-reachable production flow
   yet. The private client can consume an authoritative Core projection and a
   device-only current secret, but it cannot create or replace that projection.
3. Core's nullable RDP security projection remains a private server/client
   overlay and must land atomically with backward-compatible decoding.
4. Public `files` and `rdGateway` must remain false until actual owned-host
   acceptance proves RDPDR transfer, exact drain/Save recovery, two-stage pin
   enforcement, retirement, and disabled-session zero effect.
5. These port and widget tests do not prove DocumentsProvider effects, native
   shutdown, RDPDR bytes, Gateway TLS/NLA, or physical device behavior.
