# F27 vault reads and limits

Root review identified three remaining read-boundary defects: a resumable
chunk read created an absent directory/key, a symlinked vault root could
expose or purge its target, and an active loopback read regenerated a key
after secure-storage removal. Three focused regressions failed on those
behaviors before the repair and passed afterward.

Reads now use existing regular directories and keys. Vault root/grant links
are rejected; explicit grant purge removes a link itself instead of following
it. Manifest and chunk reads check the opened file length before a bounded
read, reject growth/type changes, and keep their 64 KiB/32 KiB limits plus
the AEAD envelope. Directory scans stop at their configured limits rather
than collecting unlimited entries first. These are Dart filesystem checks,
not a claim of an atomic operating-system `O_NOFOLLOW` open.

Production resume hashing consumes `streamChunks` one decrypted chunk at a
time. It does not retain a whole permitted multi-gigabyte download in memory.
Playback reuses the existing key, checks grant expiry for each chunk, and
flushes each chunk to apply socket backpressure. A missing key before response
headers produces an empty error response without writing a replacement key.

Root evidence:

- Before repair: 3 existing vault cases passed, **3 new cases failed**.
- After repair: both focused vault/Core loopback files, **8 passed**.
- Scoped analysis of vault and its regression test: **no issues**.
- Private logs:
  `/private/tmp/larenor-vault-existing-read-root-red-20261001.log` and
  `/private/tmp/larenor-vault-existing-read-root-green-20261001.log`.

This closes the named local read defects. F27's offline route and complete
Client/Core acceptance still require their own integration and final CI;
physical-device/provider acceptance remains separate.
