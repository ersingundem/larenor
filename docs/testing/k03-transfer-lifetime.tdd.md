# K03 Web Panel transfer lifetime evidence

This slice closes three independent Android Web Panel transfer boundaries:

1. Upload selection exposes only unique, bounded `content://` grants. The four-file limit remains, while one 25 MiB aggregate cap now applies to the complete selection.
2. Redirects, response headers, payload streaming, validation and the platform save prompt share one 30-second total deadline. Timeout retires authority and closes the HTTP client so late bytes cannot reach storage.
3. A successful platform save result is accepted only while the originating panel authority is still current after the asynchronous save returns.

## TDD evidence

- RED `14fc7eeb`: the focused test file failed to compile because the production access had no injectable total transfer deadline. The same commit specifies local-file rejection, duplicate and aggregate grant rejection, timeout suppression and post-save retirement.
- GREEN `ef3f318e`: all 10 focused transfer tests pass.

The queue remains **26/125 (20.8%)** and selected-feature progress remains **0/63 (0.0%)**. This is a bounded K03 hardening slice; it does not claim the remaining kiosk browser device and release gates.
