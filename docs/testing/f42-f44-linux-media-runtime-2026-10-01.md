# F42/F44 Linux media runtime composition — 1 October 2026

The production Server image already has a paired media runtime contract. Its
dependency stage installs FFmpeg, copies `/usr/bin/ffmpeg`,
`/usr/bin/ffprobe` and their ELF closure into the immutable runtime stage, and
sets `LARENOR_PRIVATE_EVENT_FFMPEG=/usr/bin/ffmpeg` together with
`LARENOR_PRIVATE_EVENT_FFPROBE=/usr/bin/ffprobe`. Startup rejects an unpaired
F42 configuration. The upstream tools have distinct responsibilities:
[FFmpeg](https://ffmpeg.org/ffmpeg.html) performs the decode/filter/encode
pipeline, while [ffprobe](https://ffmpeg.org/ffprobe.html) inspects streams,
format and metadata.

The Server CI shard did not install that media package. Two real F42 tests also
passed Homebrew-only paths (`/opt/homebrew/bin/...`) directly into normal Core
and the redactor. On Ubuntu those paths fail provider construction before the
real transform can run. F44's frame decoder also discovers `ffmpeg` and
`ffprobe` from `PATH`, so the same CI setup had no verified decoder pair.

The Server shard now installs Ubuntu's
[`ffmpeg` package](https://packages.ubuntu.com/noble/ffmpeg) alongside the
existing OCR dependencies before any Server tests. It requires both commands
at `/usr/bin`, requires each file to be executable, runs each version command,
and exports test-only absolute paths. The F42 fixtures select the executable
with `shutil.which`; when the CI path is present, they require it and the PATH
result to resolve to the same real executable. Missing, relative,
non-executable, mismatched or identical binary paths fail the named tests.
There is no dependency skip.

Local evidence used the installed FFmpeg/ffprobe 9.0.2 pair:

```text
python3 -m unittest -v tool.tests.server_test_workflow_test
# 3 tests, 0 failures, 0 errors, 0 skips

server/.venv/bin/python -m pytest -q \
  server/tests/test_f42_private_event_provider.py \
  server/tests/test_f42_private_event_normal_core.py \
  server/tests/test_f44_camera_visual_sensor_http.py \
  server/tests/test_f44_camera_visual_sensors.py \
  server/tests/test_f44_frigate_normal_core.py
# 31 tests: 8 F42 and 23 F44, 0 failures
```

This closes a demonstrated Linux dependency-composition gap and removes the
Homebrew-only F42 test paths. It does not claim that the prior F44 HTTP 503 had
only this cause, and it does not replace a changed-source Ubuntu CI result.

Root independently ran the same 31 F42/F44 cases and three workflow contract
tests successfully. Actionlint passed the Server and Android workflows. The
related shard/container/queue/commit validation set passed 71 tests; fixture
commits emitted by the progress tests are not repository commits.
