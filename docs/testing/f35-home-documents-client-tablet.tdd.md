# F35 home documents Android Client tablet slice

This Client slice is based directly on `main`. It models the isolated F35 Core
contract without copying the unmerged Core implementation or F34 commits. The
production HTTP/account adapter and bounded-upload resource wiring remain later
dependent slices, so F35 stays open at **21/125** and **0/63**.

Exactly three acceptance criteria are delivered:

1. Strict Client models accept only exact Core, home, account, session-family,
   account/library revision and private document/reminder projections. Unknown,
   foreign, duplicate, out-of-order and incoherent warranty results fail closed;
   only PDF/JPEG/PNG descriptors within the bounded-transfer limit are accepted.
2. The controller stages an injected bounded upload and OCR date as an
   unconfirmed suggestion. Only an admin's explicit switch plus canonical date
   starts create then confirmation; a matching authorized search/reminder
   readback is required before publication. Corrected dates are preserved and a
   member cannot upload or publish.
3. The Cupertino tablet surface supports English and Turkish, 600 and 1200
   pixel widths at 2x text scale, 48dp actions, keyboard traversal and TalkBack
   semantics. Account, route or lifecycle loss clears document, reminder and
   staged-upload state, and member mode renders only Core-authorized records
   without admin controls.

## TDD evidence

RED failed because the home-document Client feature did not exist. Focused
model, controller and widget tests cover strict authority, explicit OCR
correction, admin/member capability separation, late lifecycle results,
private projection rendering, EN/TR responsive layouts, 2x text scale, 48dp
targets, semantics and keyboard focus. These are widget/software tests and do
not claim a physical tablet, Paperless instance, production upload or complete
F35 acceptance.
