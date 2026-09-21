# F38 family memories Core foundation

Status: first Immich smart-search adapter only; F38 remains `pending` and no
progress counter change is claimed.

## Three accepted criteria

1. Every request is bound to the exact encrypted Immich service id and revision.
   The adapter accepts exactly one API-key or bearer-token credential shape,
   uses the bounded private-service transport, never redirects or retries, and
   returns only the metadata the Android memory picker needs.
2. Search is always confined to one or more administrator-allowed Immich album
   UUIDs. Person filters dispatch no network request until face search has an
   explicit policy opt-in. Turkish and other bounded language tags, date ranges,
   result counts, UUIDs, duplicate assets, image type, timestamps, filenames,
   and thumbhashes fail closed when malformed.
3. The adapter uses Immich's current `POST /api/search/smart` v3 filter shape:
   album `any`, image type, optional person `any`, and half-open capture dates.
   Tests prove policy rejection happens before transport and that retirement is
   terminal, while private owner, path, and checksum fields never cross the
   Larenor response model.

## Upstream basis

- [Immich search documentation](https://docs.immich.app/features/searching/)
- [Immich SearchController](https://github.com/immich-app/immich/blob/main/server/src/controllers/search.controller.ts)
- [Immich search DTO](https://github.com/immich-app/immich/blob/main/server/src/dtos/search.dto.ts)

## Remaining work

The encrypted selection/album manifest, personal/shared grants, quota and asset
integrity jobs, deleted-index cleanup, restore verification, authenticated Core
routes, Android tablet picker, and real Immich acceptance remain open. Face
labeling remains off unless the administrator and affected account explicitly
opt in. Originals are never copied or deleted by this foundation.
