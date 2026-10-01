# F30 synthetic archive color contract — 1 October 2026

Exact `5325c083970096fc84da2daa63b6b2a2f208aed2` broad
[run 36816909489](https://github.com/ersingundem/larenor/actions/runs/36816909489)
failed seven archive verifier/encoder/engine tests. The two direct verifier
tracebacks reached the combined codec/video/copied-track assertion at
`verifier.py:238`; the retained log does not identify which individual field
failed. Five dependent durable engine receipts failed later. No production
acceptance is inferred from those failures.

That runner used FFmpeg `6.1.1-3ubuntu5`. The primary
[FFmpeg n6.1.1 libx265 implementation](https://github.com/FFmpeg/FFmpeg/blob/n6.1.1/libavcodec/libx265.c#L231)
always enables the VUI video-signal field and derives a range for unspecified
input. The previous positive synthetic fixture left the range unspecified,
while the production verifier correctly requires exact preserved metadata.
The version difference is a source-backed portability explanation, not a
retained per-field proof of the historical failures.

The two-second synthetic positive source now explicitly declares 8-bit YUV,
limited range and BT.709 color space. A real FFprobe regression checks those
facts on both original and output. A separate actual HEVC encode changes its
range and must be rejected. All production verifier equality, compressed-track
hash, full decode, smaller-output, durable install/cleanup and retained-original
requirements remain unchanged; unknown household media is not reclassified.

Root passed all 37 tests in the three actual FFmpeg verifier, encoder and engine
files on macOS. Three workflow policy tests plus 11 isolation subtests and
`actionlint` passed. The new `f30-media` manual scope runs the same three files
on Ubuntu with the actual paired `/usr/bin/ffmpeg` and `/usr/bin/ffprobe`, the
reviewed Server lock, and a JUnit gate requiring positive tests and zero
failures/errors/skips. It leaves every broad reusable required gate intact.

Changed-source Linux acceptance is pending. F30 remains `awaiting_ci`; this
fixture repair is not a real provider, household archive or final-HEAD proof.
