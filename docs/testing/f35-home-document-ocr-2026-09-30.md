# F35 real home-document OCR candidate

Home-document upload already stores one encrypted, digest-bound product blob
behind the current Home resource ACL. F35 now reads that exact current blob on
Core and runs a bounded local Poppler/Tesseract pipeline. The Client sends no
native path, executable, language, page range, output path or OCR text.

For PDFs Core rasterizes only pages 1–3 with a fixed long-side limit of 1600
pixels. Direct PNG/JPEG inputs and generated pages must remain within 8192
pixels per side and eight million pixels. Input remains under the existing
256 KiB blob limit. Raster output is capped at 16 MiB, TSV at 1 MiB and 10,000
rows, and the complete pipeline has a 20-second deadline. Processes receive a
minimal environment, run in a private temporary directory with fixed argv,
have no shell, and are killed as a process group on deadline or output breach.
On the production Linux runtime Core also applies 20 CPU seconds, 512 MiB
address-space and per-command output-file limits with `prlimit` immediately
after spawn; OCR thread counts are fixed to one.

Tesseract TSV supplies word confidence. Core only considers a valid ISO
`YYYY-MM-DD` on a line containing a literal warranty/expiry cue. It does not
guess locale-dependent dates, treat a purchase date as warranty expiry, or
invent a result when no matching text exists. Raw recognized text, bounding
boxes and document bytes are never returned or stored in the home-document
record.

The candidate is explicitly marked `provider=tesseract` and binds its source
blob revision, SHA-256 digest and content type. It remains an untrusted
suggestion. Before returning it, Core rechecks the account/session, ACL and
exact current blob. Creating a document with a candidate reruns OCR and demands
an exact match, so a Client cannot alter the date or confidence. A candidate
never creates a reminder; the admin must separately confirm or correct the
warranty date. Confirmation records the current account and timestamp.
Candidates persisted by the older provider-less schema remain readable as
`legacy_unverified`; they are never upgraded to Tesseract evidence or accepted
as a new trusted-provider candidate.

The normal container installs `tesseract-ocr` and `poppler-utils`, copies their
ELF dependency closure and data files, exposes only fixed absolute executable
paths, and verifies the English model during image build.

Primary contracts:

- [Tesseract command-line and TSV output contract](https://github.com/tesseract-ocr/tesseract/blob/main/doc/tesseract.1.asc)
- [Tesseract official repository and supported image/output formats](https://github.com/tesseract-ocr/tesseract)
- [Poppler `pdftoppm` page, scale and PNG options](https://manpages.debian.org/bookworm/poppler-utils/pdftoppm.1.en.html)

Focused verification:

```text
LARENOR_TEST_TESSERACT=/opt/homebrew/bin/tesseract \
LARENOR_TEST_PDFTOPPM=<bundled-absolute-pdftoppm> \
server/.venv/bin/pytest -q server/tests/test_home_documents_contract.py \
  server/tests/test_home_documents_http.py \
  server/tests/test_f35_home_document_ocr.py

LARENOR_TEST_TESSERACT=/opt/homebrew/bin/tesseract \
LARENOR_TEST_PDFTOPPM=<bundled-absolute-pdftoppm> \
server/.venv/bin/python server/tests/support/f35_flutter_acceptance.py

flutter test test/features/home_documents
flutter analyze lib/features/home_documents test/features/home_documents
```

Executed results: 24 focused Server tests passed (including runtime composition); 14 focused Flutter tests passed with one expected standalone platform skip; one real Flutter Client→normal Core→upload→actual Poppler/Tesseract→create→explicit confirmation/readback passed; scoped analyze clean. Container policy: 21 passed. Local Tesseract was 5.5.3; the acceptance used the bundled absolute Poppler binary. Docker daemon was unavailable, so the final image build remains an exact HEAD CI gate. Full cross-feature CI and household documents/manual device gates remain open; this is implementation evidence, not final feature acceptance.
