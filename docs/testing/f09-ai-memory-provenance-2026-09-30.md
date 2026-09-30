# F09 AI memory provenance boundary — 30 September 2026

The authenticated public remember and correct routes create only `manual`
memory. A Client cannot label its own text as `assistant`, `automation` or
`integration` evidence. The server derives `learnedBy` from the current actor;
it is never accepted as an identity assertion from those routes.

The JSON backup format remains able to describe older records so existing
exports remain readable, but the public restore route accepts only manual
records whose `learnedBy` label matches the current authenticated account. It
then writes the current actor label rather than the request property. Provenance
is validated before tombstones or records are processed, so a forged record
cannot use an otherwise valid tombstone to cause a partial mutation.

The Client exposes no source selector for remember or correct. Both operations
always send `manual`; exported records retain their exact source kind and the
restore encoder does not relabel older records. The memory list renders the
localized kind together with the provider description, so an older assistant,
automation or integration record cannot appear as an unlabeled provider string.
These older non-manual labels explicitly say previously declared source; they
are not asserted to be authenticated provider receipts.
The typed snapshot parser also validates the account binding separately from
the three-field server context instead of silently weakening either shape.

No receipt-bound assistant or automation writer exists in the current runtime:
the AI worker exposes bounded job execution but does not emit an authenticated
memory receipt. This slice therefore does not add a privileged writer or claim
that any memory was learned by an assistant. A future trusted writer must bind
the exact worker receipt, account/session, action and source revision before it
can use a non-manual source kind.

This boundary follows the [NIST definition of provenance](https://csrc.nist.gov/glossary/term/provenance),
which includes origin, ownership and the actors or processes that changed data,
and [OWASP API3:2023](https://api-security.owasp.org/editions/2023/en/0x11-t10/),
which identifies client-controlled protected object properties as an
authorization boundary rather than ordinary editable fields.

Focused acceptance covers all three forged non-manual kinds on create and
correct, forged restore source, forged restore actor with an accompanying
tombstone, and a valid current-actor manual restore. The normal F08–F11
acceptance remains included to prove correction, forget, expiry, isolation and
tombstone behavior. `uv run pytest tests/test_f09_ai_memory_provenance.py
tests/test_f08_f11_final.py -q` passed **10 tests**; `py_compile` and
`git diff --check` passed.

`uv run python tests/support/f09_flutter_acceptance.py` passed **2 Flutter
tests** against a disposable normal Core TCP server. The gate signs in through
the real Client transport and covers manual source/user/duration, indexed
search, correction, export, forget, restore and the server rejection of a
typed legacy assistant record while proving that the Client preserved its
original source kind. `flutter analyze lib/features/server/ai_memory
test/features/server/server_ai_memory_normal_core_test.dart` completed with no
issues.
