# F24–F27 normal player/Core composition gap — 1 October 2026

**Historical finding, now superseded:** the ordinary Core-bound player and
offline cold-start composition blockers below were repaired and independently
reviewed. F21/F24–F27 now await CI; they are not accepted/done. See the
[named source and validation closure](media-core-composition-closure-2026-10-01.md).

Independent review and root source inspection found a normal product route
gap. `MediaHubScreen` sends a verified Core home to
`ServerMediaCatalogScreen`; the local Jellyfin player remains behind the
direct-local service route. `OperationalServiceScreen` makes the same route
choice. On a cold direct-local startup, `HomeSessionController` restores the
Core account only for `HomeSource.verifiedCore`.

The real player nevertheless constructs Core-authorized quality, segment,
watch-party and offline controllers. Those controllers require an initialized
current Core account, an authenticated session family and a verified context.
Track preference persistence requires Core authority too. An undocumented
same-process source switch can leave a previously initialized account around,
but it is not a usable cold-start composition or a safe authority contract.

The existing store/API and injected player-controller gates do not establish
this normal navigation/startup path. F24 track preferences, F25 segments, F26
quality and F27 offline media therefore return to `reworking`. Their earlier
narrow evidence remains historical; they cannot await only CI while this
production entry is incomplete. F21 watch-party also returns to `reworking`: the existing two-process Core room/leader/restart gate passes explicit targets and positions into its controller; it does not open the normal player and measure the applied directive there.

The repair must provide an explicit normal player entry with exact current
Core/home/provider authority. It must not silently combine unrelated direct
Jellyfin and Core homes or export private provider credentials as a shortcut.
Cold startup, restart, authority replacement and route retirement must be
covered before these features return to `awaiting_ci`.
