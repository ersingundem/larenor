# Retained Music Assistant status

Larenor Core now exposes one authenticated, administrator-only read model for
the Music Assistant chain it retains. `GET
/api/v1/admin/media/music-assistant/retained` joins the managed installation
registry, authenticated Music Assistant bootstrap readback, exact Home
Assistant and Jellyfin service revisions, and provider setup journals.

The response has four explicit top-level states:

- `unknown`: no retained Music Assistant installation exists.
- `partial`: installation, bootstrap, or provider readiness is incomplete.
- `failed`: an installation failed, a bound service revision changed, or a
  provider setup reached an attention/cancelled state.
- `ready`: the exact installation revision has a current authenticated
  bootstrap receipt and at least one provider has authenticated ready state.

`installAvailable` remains `false`. This endpoint never creates, starts,
restarts, retries, cancels, or repairs a container or provider flow. It does not
return service endpoints, access tokens, cookies, bootstrap credentials,
provider flow identifiers, redirect URLs, or media account data. Historical
provider records tied to a different installation revision are not promoted to
the replacement installation.

The Android administration route is linked from the existing PIN-protected
media preparation screen. It performs one explicit read on entry and another
only when the administrator presses Refresh. Losing the route, Settings PIN,
Core account, administrator role, app foreground, or request generation clears
the result and prevents a late response from appearing.

The tablet layout uses the shared grouped surface and 1000 px readable column,
48 dp refresh control, semantic headings/live status, wrapping text, and exact
ids plus revisions. Focused fixtures cover English and Turkish at 2x text on a
600 px tablet window and a 1280 px DeX window.

Native retained-daemon liveness, a process restart during an in-flight worker
operation, real Music Assistant account setup, and HomePod/AirPlay playback
remain physical acceptance boundaries. The projection reports only committed
Core records and never infers live health from a socket path or container name.
