# epidemica_proximity_ios

iOS implementation of `ProximityPlatform`. You do not depend on this package directly —
[`epidemica_proximity`](../epidemica_proximity) endorses it, so adding that one dependency is
enough.

Herald arrives through **Swift Package Manager**, pinned to 2.2.0. A CocoaPods podspec is the
fallback if an app build turns up an SPM problem.

## Layout

| Path | Role |
| --- | --- |
| `wire/` | A standalone Swift package holding the wire codec, with no dependency on Flutter or Herald. |
| `ios/epidemica_proximity_ios/Package.swift` | The plugin package: Herald plus the wire codec. |
| `.../Sources/.../ProximityEvents.swift` | Bounded buffer and `FlutterEventSink` glue. |
| `.../Sources/.../EpidemicaPayloadSupplier.swift` | Supplies the 18 advertised bytes to Herald. |
| `.../Sources/.../ProximitySensor.swift` | Herald lifecycle, including BLE state-restoration handling. |
| `.../Sources/.../EpidemicaProximityPlugin.swift` | Method and event channels; the `Info.plist` preflight check. |

The codec lives in its own package precisely so it can be tested without an Xcode project, a
simulator or an app:

```sh
cd wire && swift test    # 6 tests, well under a second
```

Those tests decode the [shared wire vectors](../../contracts/wire/proximity_payload/1.0.0.vectors.json)
that the Kotlin implementation also decodes. That file is the only thing keeping the two platforms
byte-compatible before hardware exists to prove it.

## Two pieces of hard-won behaviour

**State restoration.** iOS relaunches the app in the background for Bluetooth events, and a
`SensorArray` left over from the previous session points at a dead BLE stack — it looks alive and
reports nothing. `ProximitySensor` tracks whether *this process* has started sensing, and discards
anything inherited. This logic is ported from Epigames and is the reason background detection works
at all after a kill.

**Info.plist preflight.** iOS has no manifest merging, so the required keys must be added to the app
target by hand. Missing them causes no crash — sensing simply stops when the screen locks.
`missingPlatformRequirements()` reads `Bundle.main` and reports exactly what is absent, and `start()`
refuses rather than pretending to work. The keys are listed verbatim in the
[main README](../epidemica_proximity/README.md#ios--manual-and-silent-if-you-get-it-wrong).

## Notes

- **Minimum deployment target iOS 13.**
- **Herald is unmaintained** — 2.2.0 is three years old and upstream testing is claimed only to iOS
  14.6. Confining it to this package is the mitigation.
- SPM *resolution* is verified. Whether Herald still **compiles** under Xcode 26 needs an app build
  to settle, because SwiftPM cannot cross-compile UIKit from the command line.
