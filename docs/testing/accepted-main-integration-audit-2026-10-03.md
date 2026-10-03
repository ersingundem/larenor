# Accepted work and main integration audit — 2026-10-03

Inspected completion snapshot `7736683371a6b955a0d4f04a0ba4f9460a9246f0` and freshly fetched
`origin/main` `ffad53643876315deac6ab091d76085a75831c0e`. Later F60 commit `847b1f576ebab39ab92c9cd008c036a817672188` does not change the accepted counters.

All 35 nonbaseline done tasks, including the three selected features, have
recorded acceptance criteria, passed evidence, and satisfied direct/group
dependencies. This checks the existing scoped acceptance records; it does not
replace current combined CI or reopen physical acceptance as software evidence.

| Main representation | Tasks |
| --- | ---: |
| Exact completion commit in main ancestry | 25 |
| Direct or aggregate stable squash patch identity | 6 |
| Content present, with bounded later changes on main | 4 |

Main marks 32 of these 35 tasks done. F06 and F31 code and evidence are exact
ancestors, while their status promotions remain on the completion branch.
F34 code has the same stable patch identity as main commit
`a1fc2d7fe26830a9dbd758d1e69ac6647951a564`; its closure document
`docs/testing/f34-software-closure-2026-09-27.md` and acceptance promotion
are not yet present on main. K07/K08 are correctly reopened as awaiting CI on
the completion branch, while main retains their earlier done labels.

| ID | Representation | Main status |
| --- | --- | --- |
| S06.3a | Exact ancestor | done |
| S06.3b | Exact ancestor | done |
| S06.3c | Exact ancestor | done |
| S06.3d | Exact ancestor | done |
| S06.3e | Exact ancestor | done |
| S06.3f | Exact ancestor | done |
| S06.4 | Stable direct patch | done |
| S06.5 | Exact ancestor | done |
| S06.6 | Exact ancestor | done |
| S07.1 | Exact ancestor | done |
| S07.2 | Exact ancestor | done |
| S07.3 | Exact ancestor | done |
| S07.4 | Exact ancestor | done |
| S08.1 | Exact ancestor | done |
| S08.2 | Exact ancestor | done |
| S08.3 | Exact ancestor | done |
| S08.4 | Exact ancestor | done |
| S08.5 | Exact ancestor | done |
| S08.6 | Exact ancestor | done |
| S08.7 | Exact ancestor | done |
| S08.8 | Present content; later changes inspected | done |
| S08.9 | Exact ancestor | done |
| S08.10 | Exact ancestor | done |
| S08.11 | Stable aggregate patch | done |
| S09.1 | Present content; later changes inspected | done |
| S09.2 | Stable aggregate patch | done |
| S09.3 | Stable aggregate patch | done |
| B5.1 | Exact ancestor | done |
| B5.2 | Exact ancestor | done |
| K03.remaining | Stable aggregate patch | done |
| K05.remaining | Present content; later changes inspected | done |
| F06 | Exact ancestor | pending |
| F31 | Exact ancestor | pending |
| F34 | Stable code patch; closure document absent | pending |
| REMOTE.COMMON | Present content; later changes inspected | done |

Root independently rechecked all 25 exact ancestry claims, every local
evidence-reference existence claim, and both direct squash patch identities.
The four evolved scopes are S08.8, S09.1, K05.remaining, and REMOTE.COMMON;
their inspected later differences concern already evolved routing, tests, or
evidence documents. The aggregate identities are retained in the private audit.

Private audit SHA-256:
`ef5b5a9753844be77eedc27efbcafb206ca0f63f2e52dcf366b6ee537a451947`.

## Required next-final gate

The completion snapshot is not an ancestor of main. F60/F62 are reworking,
69 tasks and 58 selected features await combined CI, and FINAL.FUNCTION is
active. No next final may start until all software acceptance and dependency
gates pass, the final completion HEAD passes required CI, the branch is merged
into main, and freshly fetched main ancestry plus accepted content are checked.
Final.UI then uses one new branch from updated main. No status is promoted by
a local compile, a fixture-only probe, or this audit.

Live recheck after exact completion HEAD `3f23132ffc4ac151ee2ad3f35fc9e274a3c0e573`: remote main remains `ffad53643876315deac6ab091d76085a75831c0e`. The sole open PR is Dependabot #493 at `ead7fbce30f474fd248495a836b34673ebc3d07f`, blocked with no auto-merge. No completion merge or next-final branch has occurred. The 35 accepted-task representations above remain unchanged; status/closure integration and all final gates remain open.
