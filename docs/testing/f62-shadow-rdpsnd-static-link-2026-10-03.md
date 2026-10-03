# F62 static shadow rdpsnd link repair — 2026-10-03

## Observed bounded failure

Run `37142705819` at source `0cadf0ef9719d2cba1b050ddb09d4624219b9675` produced the canonical schema-4 build-failure receipt (artifact `11280354852`, JSON SHA-256 `c6bad79ad2f59f7a2be19d97f32942f8c4441b3c5436753d14a651eab26cf7df`). The exact failure was `compile/linkerError`, target `shadowCli`, two undefined identifiers, and `featureAccepted=false`. Source extraction, reviewed target-patch verification, and CMake configuration had completed.

An exhaustive identifier hash comparison against pinned FreeRDP `63b948ca5cb94307fd5444ee6e73927a41ccdab4` resolves the two published hashes to `rdpsnd_server_context_new` and `rdpsnd_server_context_free`. Both are implemented by `channels/rdpsnd/server/rdpsnd_main.c`, whose CMake target is the OBJECT library `rdpsnd-server`. `server/shadow/shadow_rdpsnd.c` calls both functions. The static probe compiles that file into `freerdp-shadow`, but the target had only the aggregate `freerdp-server` dependency; its private static channel dependencies do not place the `rdpsnd-server` object members into the final shadow CLI link.

## Narrow repair

The probe continues to apply and verify the existing RDPDR patch and manifest without changing either digest. A separate exact patch, SHA-256 `dce0885933ae80e4de02da94cd43a7a3df1080cf1644243fd00d1fb12f9a3d7d`, changes only `server/shadow/CMakeLists.txt` after the existing patch is verified. It:

- adds `rdpsnd-server` directly to `freerdp-shadow` only when `BUILD_SHARED_LIBS` is false;
- fails CMake configuration if that exact target is unavailable;
- leaves shared builds and `xfreerdp` unchanged.

The probe enables only the rdpsnd server target (`CHANNEL_RDPSND=ON`, `CHANNEL_RDPSND_SERVER=ON`, `CHANNEL_RDPSND_CLIENT=OFF`). Before applying the repair it requires the exact target-patched CMake SHA-256 `59c773bfcdb6fd138d553b0b0583e8fb66eb596c58a31f435848ac5ec3937312`; afterward it requires `3447a610ff7b3ec73511cf0bad8a97e8a31b8029748474231db1a68415eefd38`. Drift, a duplicate/pre-applied patch, patch failure, or unexpected output fails closed.

## Evidence and limits

Focused Python tests cover the exact patch digest, static-only guard, exact target, no CLI/client injection, required CMake flags, source drift, duplicate injection, and exact before/after composition. This private repair has not compiled FreeRDP and has not passed a changed-source hosted run. It does not prove Gateway, NLA, RDPDR, Android, or feature acceptance; the strict effect gate remains unchanged.

## Shared root verification

Root integrated exactly the four manifest-bound paths against `b6f4ebabc7103e090bf5156b9353a89b7192c8f3`. Combined probe/build-diagnostic/workflow tests passed **60 tests and11subtests**, zero failure/error/skip; Ruff0.14.1 passed. Frozen root log SHA-256 `9b16c315a073345f48bd840077b7421ab59d9cea9a8480bc58526b5b13a2b46c`. Root independently verified the canonical failure bytes, closed schema4 keys, exact source/archive/patch/manifest pins, target and both symbol hashes. The changed-source hosted build/effect gate is still open.
