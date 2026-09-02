# epidemica_proximity_android

Android implementation of `ProximityPlatform`. You do not depend on this package directly —
[`epidemica_proximity`](../epidemica_proximity) endorses it, so adding that one dependency is
enough.

Herald runs inside a foreground service. That is not optional on modern Android: without one,
scanning stops within minutes of the screen locking, and it does so silently.

## Layout

| File | Role |
| --- | --- |
| `ProximityPayload.kt` | The wire codec. Pure Kotlin, no Herald or Android types, so it unit tests on the JVM. |
| `DetectionBuffer.kt` | Bounded FIFO for detections observed while Dart is detached. Also pure. |
| `ProximityEvents.kt` | Buffer-to-`EventSink` glue. Everything routes through the buffer, which removes the attach race rather than papering over it. |
| `EpidemicaPayloadSupplier.kt` | Supplies the 18 advertised bytes to Herald. |
| `ProximityService.kt` | Foreground service; Herald lifecycle; the one `SensorDelegate` callback that carries both a payload and an RSSI. |
| `EpidemicaProximityPlugin.kt` | Method and event channels. |

Permissions and the service declaration are in `src/main/AndroidManifest.xml` and merge into the
host app automatically. They are reproduced verbatim in the
[main README](../epidemica_proximity/README.md#android--automatic).

## Testing

```sh
cd ../epidemica_proximity/example/android \
  && ./gradlew :epidemica_proximity_android:testDebugUnitTest
```

The tests need a Gradle context, which the example app provides. They check the codec against the
[shared wire vectors](../../contracts/wire/proximity_payload/1.0.0.vectors.json) that the Swift
implementation also decodes, and cover buffer overflow accounting under concurrent writers.

## Notes

- **minSdk 24, compileSdk 35.** Herald itself supports API 21+.
- **No location permission above API 30.** `BLUETOOTH_SCAN` is flagged `neverForLocation`; the
  location permissions are capped at `maxSdkVersion="30"` for devices that genuinely need them.
- **Flutter is deprecating Kotlin-applying plugins.** The build warns about this. Herald for Android
  is pure Java, so rewriting these ~300 lines in Java would retire both the warning and a toolchain
  dependency.
