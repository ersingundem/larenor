# B5.1 navigation, Keenetic and status tablet acceptance

## Scope

This slice accepts three related tablet surfaces without advancing the selected
feature backlog. The queue baseline remains `17/125` and the feature baseline
remains `0/63`.

## Acceptance criteria

| Surface | Required evidence | Automated acceptance |
| --- | --- | --- |
| Shared navigation and search | Search and Settings stay available from daily-use roots; routine search, filters and result rows are named, keyboard reachable and use 48 dp minimum controls. Opening a routine only reviews the current entity and never executes it. | EN/TR at 600/1200 px with 200% text, keyboard activation of global search and routine rows, keyboard filter selection, no HA writes, and removed-entity callback rejection. |
| Keenetic panel and detail widgets | The base, details, mesh, clients and bandwidth choices return a server-verified draft through the real picker. A retained choice cannot use a changed resource or ACL revision. | EN/TR picker matrix at 600/1200 px with 200% text, 48 dp button semantics, all five draft variants, stale-resource rejection, and 600/1280 card layout regressions. |
| Connection and operation state | Saved configuration, reachable transport and a verified domain read remain distinct passive evidence. Opening a service uses the real guarded route; missing or failed configuration goes to protected Settings without starting a remote client. | System screen state transitions, generic retry, credential removal, operational back navigation, EN/TR 600/1200 px keyboard routes, plus connection-evidence regressions. |

## Verification boundary

All tests use synthetic providers, local stores and fake clients. They contact
no Home Assistant, Keenetic, Proxmox or media endpoint. Physical Huawei tablet,
DeX, keyboard and TalkBack checks remain device acceptance work.
