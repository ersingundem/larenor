# B5.1 direct connection forms tablet acceptance

This slice aligns three direct-local setup surfaces without changing their
credential stores, verification transports, or authority owners. Queue progress
remains `17/125`; selected-feature progress remains `0/63`.

1. **Keenetic connection:** The URL, account and password form uses the shared
   tablet surface and settings section. Its visible and keyboard-submit actions
   are 48 dp, expose one localized button semantics node, and keep gateway
   discovery, route visibility, Direct Home authority and provider generation
   checks fail-closed.
2. **Jellyfin connection:** Manual and discovered-server setup uses the same
   tablet hierarchy. A discovered server is a keyboard-reachable 48 dp action;
   password Done and the visible Connect action invoke the same captured
   connection owner. Native focus, lifecycle, route or provider retirement
   clears the draft and makes retained callbacks inert.
3. **qBittorrent connection:** The manual and LAN-discovery form uses the shared
   surface, grouped fields, 48 dp Connect/remove actions and password Done
   submission. Direct Home, lifecycle, route and provider changes continue to
   cancel owned verification and cannot publish late credential results.

The focused matrix covers English and Turkish at 600 and 1200 logical pixels
with 2x text, button semantics and keyboard Done. Existing direct-recovery
suites exercise PIN recovery, route coverage, lifecycle/background, source and
provider replacement, storage quarantine and late callback rejection.
