# F41 camera search Core-to-tablet integration — acceptance evidence

## Acceptance criteria

1. **Discoverable shared tablet route.** Verified-Core homes expose a localized
   camera recording search row in the common Core home surface. The 48dp,
   keyboard-accessible row opens `/camera-search`; the route uses the same
   shared tablet shell and EN/TR copy at 600/1200/1280 widths and 2x text scale.
2. **Exact authenticated discovery and search.** The route first reads the
   authenticated Core search context, then binds its Core, home, session object,
   account generation, interaction epoch, window/route lifecycle, index
   revision and authorized camera IDs into one route-owned controller. Search
   sends only that discovered revision and bounded camera set.
3. **Late authority is fail closed.** Core derives context from the live account
   authority and Client discards discovery or search responses after a home,
   account, session, route, window or lifecycle change. A delayed result cannot
   repopulate the screen, and old evidence is never retained across a rebind.

## Automated evidence

Validation on 2026-09-21:

- Core index and authenticated route suite: 11 passed.
- Client API/controller/screen/route and common Core-home tablet suite: 16
  passed.
- EN/TR screen matrix covers 600 and 1280 logical pixels at 2x text scale; the
  shared Core-home entry covers 600 and 1200 logical pixels at 2x.
- Hardware Enter submission, TalkBack action labels, 48dp entry/action sizing,
  exact context discovery, authenticated search and late-home cancellation are
  covered.

## Remaining physical acceptance

Production still needs an NVR metadata ingestion adapter and a live
membership/camera-grant resolver. Physical camera/NVR search quality, clip
playback, Huawei tablet and Samsung DeX checks remain manual. This integration
does not claim those results and does not close F41 progress by itself.
