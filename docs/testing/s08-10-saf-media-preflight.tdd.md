# S08.10 SAF media preflight

20 September 2026. This independent Android Client slice closes three software checks immediately before Storage Access Framework publication:

1. only a closed set of bounded document, image, audio and video media types can reach the document picker;
2. known binary types must match their local magic-byte contract, while text and JSON must be valid UTF-8 and JSON respectively;
3. active, unknown, parameter-smuggled or MIME/signature-mismatched content fails before the picker callback and is never retried.

The policy supports plain UTF-8 text, JSON, PDF, PNG, JPEG, WebP, MP3, FLAC, WAV, Ogg audio, MP4 video and WebM. HTML, SVG, JavaScript, generic octet streams, extra content-type parameters and malformed payloads are closed failures. The existing verified transfer digest, length, frame, durable receipt, lifecycle and authority checks still run before this final local preflight.

## TDD evidence

| Guarantee | Evidence | Result |
| --- | --- | --- |
| Missing pre-SAF media policy was specified first | `921e9250`; the focused test failed because `CoreBoundedMediaPreflight` did not exist | RED |
| Supported document/media payload contracts | Valid UTF-8/JSON and ten binary signature cases | PASS |
| Active and ambiguous content remains closed | HTML, SVG, JavaScript, octet-stream, smuggled parameters and malformed payload cases | PASS |
| MIME/signature drift cannot invoke SAF | Real loopback bounded downloads for ten mismatched media declarations; picker call count remains zero | PASS |
| Existing authority, lifecycle, receipt and upload regressions remain compatible | Focused controller suite | PASS |
| Owned source and test remain statically clean | Targeted `flutter analyze --no-pub` | PASS |

The combined focused Flutter run completed with **16 PASS** and zero skips. This does not claim support for every codec/container, physical Huawei/DeX SAF behavior, or close all S08.10 work. Queue progress remains 15/125 and selected feature progress remains 0/63.
