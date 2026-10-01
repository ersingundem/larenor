# Host-worker plugin artifact mode — 2026-10-01

The full Server test process runs with `umask 077`. Before this repair,
`plugin_package.main()` passed `0644` to `os.open()`, so both real callback and
encoder ZIP artifacts were created as `0600`. The installer correctly rejected
those files because its offline release contract requires an exact regular,
single-link, owner-matching `0644` artifact.

The package writer now creates the new exclusive, no-follow descriptor as
private `0600`, writes and syncs the complete ZIP, then applies exact `0644`
with `fchmod()` and syncs the descriptor again. This makes the final contract
independent of process umask without exposing a partially written public file.
The existing exclusive-create behavior is unchanged, and a focused symlink
regression proves that a pre-existing target is not touched.

## Focused evidence

- RED: both parameterized real-package cases failed their exact `0644`
  assertion under an explicit `umask 077`; the observed mode was `0600`.
- GREEN: the callback and encoder cases pass under the same explicit umask and
  then pass the production installer artifact validator.
- The symlink rejection regression passes and preserves the target bytes.
- These tests exercise local synthetic artifacts only. They do not install or
  activate host workers and do not access a household device.
