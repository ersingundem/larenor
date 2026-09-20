# B5.1 Proxmox connection, template and console acceptance

This slice keeps the three entry workflows on the shared tablet surface without
changing the Proxmox session owner or transport boundary.

1. **Connection:** The direct Proxmox form uses the shared tablet surface and
   grouped settings hierarchy. Connect and recovery actions keep a 48 dp target;
   the password keyboard action submits the same validated, current
   Direct-Home/session-bound operation as the visible button. Errors are
   announced as a live region, and a hidden, replaced or unfocused route cannot
   finish the connection.
2. **Create from template:** Template, storage and clone actions expose one
   button semantics node, a 48 dp target and Enter activation. The selected
   node, template and storage remain bound to the captured Proxmox account and
   route lease; an expired lease leaves an accepted mutation in explicit review
   state instead of replaying it.
3. **Console:** Web sign-in, refresh and console-open actions use the same
   settings-card hierarchy and keyboard contract. Opening a console still loads
   the concrete same-origin HTTPS route for the captured node, guest type and
   VM ID; TLS, account, route, target or lifecycle drift retires the WebView and
   cannot turn a late callback into a successful session.

The focused widget matrix covers English and Turkish at 600 and 1200 logical
pixels with 2x text. Existing Proxmox recovery, mutation and session suites
cover stale callbacks, route/lifecycle invalidation, exact source authority and
real console URL behavior.
