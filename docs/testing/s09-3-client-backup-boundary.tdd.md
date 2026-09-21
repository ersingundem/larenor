# S09.3 Client backup boundary foundation

Date: 2026-09-21

This slice gives an authenticated Larenor Core administrator a read-only tablet
view of the exact Server backup plan. It deliberately adds no restore mutation:
the Server authenticates and publishes a bundle only into an empty Core before
that Core starts.

The three acceptance criteria are:

1. The Client accepts only the closed version-1 manifest, exact four-resource
   set, bounded component map, known blocker vocabulary, safe versions, byte
   lengths and SHA-256 digests. Unknown fields and incoherent ready/blocked
   states fail closed.
2. The readiness GET is bound to the current administrator session and visible
   route. Account replacement, role loss, cancellation or a late response
   retires the result; members dispatch no request and the screen sends no
   mutation or automatic retry.
3. English and Turkish tablet layouts expose ready/blocked state, protected
   resource sizes and the empty-Core recovery boundary at 600/1280 widths with
   2x text. The Settings entry is available only to a verified administrator.

Focused verification covers six model/controller/widget tests and the existing
24 Server connection widget tests. Targeted Flutter analysis plus security,
execution-queue, progress and diff policy checks remain required. This
foundation does not export a large bundle through Android memory, restore a
running Core, close S09.3, or replace the two-architecture container gate.
