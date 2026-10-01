# F62 basic keyboard and Unicode input evidence — 2026-10-01

## Implemented boundary

The RDP Client now forwards a closed USB keyboard-page surface through the
packaged FreeRDP engine. Letters, number row, punctuation, navigation, keypad,
F1–F24, and left/right modifier usages map to Windows virtual-key values before
FreeRDP converts them to RDP scan codes. Consumer/system usages and unimplemented
keyboard usages stay with Flutter/Android: they return `ignored`, consume no RDP
input sequence, and do not retire the session.

The selected keyboard layout is part of the real connection URI:

- automatic: `/kbd:unicode:on`;
- Turkish Q: `/kbd:layout:1055,unicode:on` (`0000041F`);
- US: `/kbd:layout:1033,unicode:on` (`00000409`).

The packaged capability says the engine can negotiate text input. Text controls
remain hidden until the authenticated connection reports
`LibFreeRDP.isUnicodeInputSupported(instance) == true`. The exact open response
binds that fact to the current native session. Retirement clears it, and a later
session must negotiate again.

Composed text accepts 1–4096 bytes of valid UTF-8 with no NUL or unpaired
surrogate. Native converts it back to a checked UTF-16 code-unit sequence and
sends each code unit down/up through `sendUnicodeKeyEvent`. This preserves
Turkish characters and supplementary-plane surrogate pairs. A partial native
send is uncertain: the session closes and the Client never replays the text.
Text and credentials are neither logged nor persisted.

## Source contract

The implementation is tied to FreeRDP 3.31.1 commit
`63b948ca5cb94307fd5444ee6e73927a41ccdab4` and the receipted Android API:

- `LibFreeRDP.java`: `sendKeyEvent`, `sendUnicodeKeyEvent`, and
  `isUnicodeInputSupported`;
- `android_freerdp.c`: virtual-key-to-scan-code conversion and the `UINT16`
  Unicode event boundary;
- `client/common/cmdline.c`: `kbd` layout and `unicode:on` options;
- `KeyboardMapper.java`: the Windows virtual-key constants consumed by the JNI
  key path.

Microsoft's keyboard identifier table defines Turkish Q as `0000041F` and US
as `00000409`. The pinned FreeRDP input path rejects Unicode events when the
server did not negotiate `FreeRDP_UnicodeInput`; local settings alone are not
treated as proof.

Primary references:

- <https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/Studio/freeRDPCore/src/main/java/com/freerdp/freerdpcore/services/LibFreeRDP.java>
- <https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/libfreerdp/core/input.c>
- <https://learn.microsoft.com/en-us/globalization/keyboards/kbdtuq>

## Focused evidence

Red-first proof: the native focused test compile initially failed because
`unicodeInputSupported` and the session negotiation boundary did not exist.

Final gates:

- Flutter: four focused RDP files, **48 passed**, zero failures.
- Native common/bridge: **18 passed**, zero skipped/failures/errors.
- Exact packaged FreeRDP keyboard contract: **3 passed**, zero
  skipped/failures/errors.
- The packaged gate used AAR SHA-256
  `03ea2f3fbee95a6ca7bd92703ac8c2d529a6a36e3edbfc890cbc6ea256cdfb2f`
  and receipt SHA-256
  `ac4804d32f77a50950f774bff1f5442805fe9bc00104b0041713595f5eec14f1`.
  `freerdp_android_package.py verify-install` accepted the pair before the
  source set compiled and ran. The ignored combined product package was restored
  byte-for-byte after the temporary mount.

The software evidence proves request shape, layout consumption, negotiated UI
gating, bounded UTF-16 conversion, Windows VK mapping, lifecycle fencing, and
nonfatal unsupported keys. A changed-source owned Windows-host witness must
still observe Turkish/supplementary text and modifier/shortcut effects through
the real session before those provider effects are accepted. Physical keyboard
variants and IME behavior remain device/manual coverage. Display/pointer,
remote audio, microphone, and SAF redirection are separate F62 slices; this
slice does not mark F62 complete.

## Independent root verification

The root narrowed nonfatal false native replies to key input only. A new
regression proves that a false pointer reply retires the exact channel, while
a false key reply does not. All four focused Dart suites then passed 49 tests,
and scoped analysis of eight Dart files reported no issues. Root output:
`/private/tmp/larenor-root-verify-20261001/f62-keyboard.log` and
`f62-analyze.log`. This does not replace the actual host effect gate.
