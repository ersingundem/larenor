# Helper base path-relation diagnostics

Native run 13 (`34279647850`) used exact source
`8f07560eeea8a51fd59c9df56ac32c52a888b4c3`. Both `linux/amd64` and
`linux/arm64` reached the same closed result:
`phase=helper_base_start code=helper_base_path_location_ambiguous`.
No success receipt or public artifact was produced.

The failed-job log was downloaded once to a private temporary path. It is
70,214 bytes and its SHA-256 is
`a8e7ac3ee4053ffc9673c91fa7de1a7f08d732f5be3926a34588efe7eb9634fb`.
Only the allowlisted phase/code pair, byte count and digest are retained here;
the private Engine state error and path values are not copied into repository
evidence.

## Narrower closed outcomes

Commit `40dc4b7cd26bd72d2fc7bcb425e23f6e579e2513` separates the five expected
relationships between the owned ephemeral Engine root and a path inside that
root:

| Closed code | Meaning |
| --- | --- |
| `helper_base_engine_image_path_failed` | Engine root and known image executable/helper path occur in one path token. |
| `helper_base_engine_proc_path_failed` | Engine root and procfs target occur in one path token. |
| `helper_base_engine_sys_path_failed` | Engine root and sysfs target occur in one path token. |
| `helper_base_engine_runtime_path_failed` | Engine root and runtime target occur in one path token. |
| `helper_base_engine_host_path_failed` | Engine root and Docker-provided host-file target occur in one path token. |

Two path families merely occurring somewhere in the same private error do not
prove a relationship. The reducer requires the exact two-family set to occur
inside one bounded path token. Two separate paths, three or more families, an
unknown combination, malformed state and unreadable state remain on their
existing ambiguous or generic closed outcomes. No path or exception text is
returned.

## Verification

Five initial relationship cases failed against the ambiguous result. An
independent review then found that two separate paths could be overstated as a
single relationship. That case failed as a sixth review regression before the
token-bound rule was implemented; a seventh regression preserves ambiguity for
three families.

The final exact commit passed 50 state tests, 82 combined state/stderr tests,
all 286 Jellyfin tests and all 218 dependency-free policy tests. Python
compilation and diff validation passed. The independent final review is CLEAR.
The one bounded owned-state inspect, single start attempt, no-retry rule,
cancellation behavior, cleanup ownership and private-output limits are
unchanged.

## Remaining gate

Native run 14 must execute this exact code on both architectures. A relation
code will identify the next safe repair boundary; another ambiguous result will
require a still narrower closed observation. Neither outcome alone authorizes
installation. Real Engine installation acceptance and `installAvailable=true`
remain open.
