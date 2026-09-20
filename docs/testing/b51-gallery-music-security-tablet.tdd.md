# B5.1 gallery, music and security tablet acceptance

## Scope

This slice records the three-screen tablet acceptance for the dashboard widget
gallery, Music Center and settings PIN gate. It keeps the queue baseline at
`17/125` and feature baseline at `0/63`; the final whole-product visual pass is
still a separate `FINAL` item.

## Acceptance criteria

| Surface | Required evidence | Automated acceptance |
| --- | --- | --- |
| Widget gallery | A keyboard or TalkBack user can choose a real widget draft; entity and website inputs are named, controls are at least 48 dp, and a stale account or retained selection cannot return a draft. | EN/TR at 600/1200 px with 200% text, URL validation, compatible entity selection, duplicate completion, account change and background expiry. |
| Music Center | Output routes and catalog items open real destinations; all controls are at least 48 dp; playback can only start from the current account, loaded catalog source and explicit confirmation. | EN/TR at 600/1200 px with 200% text, keyboard route activation, library/search/queue state, retained callbacks during account/catalog refresh, background expiry and one-shot playback dispatch. |
| Settings security | The PIN field and unlock action are named, keyboard reachable and at least 48 dp; only the current foreground verification may unlock the real settings route. | EN/TR at 600/1200 px with 200% text, Enter-key unlock, idle/background relock, delayed verification and dialog callback expiry. |

## Verification boundary

The focused tests use synthetic providers, local stores and fake media APIs;
they contact no Home Assistant, Music Assistant or other home service. Physical
Huawei tablet, DeX, keyboard and TalkBack checks remain device acceptance work.
