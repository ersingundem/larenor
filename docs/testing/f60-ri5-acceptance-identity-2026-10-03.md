# F60 RI5 acceptance identity — 2026-10-03

The exact-source stream run `37127353767` at
`9a85dc1f62193570c145cdd6656a278039570278` failed before provider setup. The
owned runner rejected the correctly built RI5 receipt because its independent
acceptance constant still named embed-v4 while the reviewed package lock and
receipt named embed-v5.

The discovery/stream package identity gate now obtains the expected engine
revision and upstream commit through the same strict
`moonlight_android_package.load_lock()` validator used by package production.
It still binds the actual AAR SHA-256, receipt class SHA-256 and source tree.
An embed-v4 receipt is rejected and the current embed-v5 receipt is accepted.

This repairs only the pre-provider identity composition. It does not establish
Sunshine pairing, streaming, frame/audio/input effects, two session lifetimes,
remote disconnect, local retirement, provider removal, CI acceptance or device
acceptance. Those original strict gates remain unchanged.

## Root integration evidence

The corrected discovery, stream and stream-workflow suite passed **86/86**
with zero failures/errors. Scoped Ruff 0.14.1 passed. The actual mounted RI5
package identity is still checked against the reviewed lock, actual AAR hash,
class hash and source tree.

The old run completed **FAILED** at package identity, before provider setup;
GitHub retained no acceptance artifact. The private failed job log SHA-256 is
`71ea10bfdedfebeeb4a1b9b5193cad2ace139268edbc00bd38abaa151ed5ca01`.
This is a pre-provider runner failure, separate from the earlier RTSP failure.
