# epidemica_proximity

Bluetooth proximity module for Epidemica. Detects nearby study participants and reduces those
sightings to **contact episodes** — time spent in each distance band — applying the study's
minimisation rules before anything reaches the outbox.

Episode payloads validate against
[`contracts/observations/proximity/contact_episode/1.0.0.json`](../../contracts/observations/proximity/contact_episode/1.0.0.json).
The bytes on the air are specified in
[`contracts/wire/proximity_payload/1.0.0.md`](../../contracts/wire/proximity_payload/1.0.0.md).

## Packages

This is a federated plugin. An app depends on `epidemica_proximity` alone; the platform
implementations are endorsed and arrive automatically.

| Package | Contains |
| --- | --- |
| `epidemica_proximity` | Episode aggregation, distance estimation, bundle configuration. Pure Dart. |
| `epidemica_proximity_platform_interface` | The Dart↔native boundary and the shared method channel. |
| `epidemica_proximity_android` | Kotlin foreground service wrapping Herald. |
| `epidemica_proximity_ios` | Swift sensor lifecycle wrapping Herald. |

Federation is not ceremony here. An institution that needs a different radio — dedicated BLE badges,
or a nationally mandated stack — registers its own `ProximityPlatform` rather than forking this
package, which [ADR-0001](../../docs/adr/0001-monorepo-and-package-boundaries.md) forbids. It also
confines Herald, which is unmaintained upstream, to two packages that can be replaced without
touching contracts, Dart, or the server.

## Installing

```yaml
dependencies:
  epidemica_proximity: ^0.1.0
```

That is the whole Dart-side integration. The platform requirements below are not.

## Platform requirements

### Android — automatic

A plugin's `AndroidManifest.xml` is merged into the host app, so **you declare nothing**. For
reference, the module contributes:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" android:maxSdkVersion="30" />

<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.WAKE_LOCK" />

<uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />

<service android:name=".ProximityService" android:exported="false"
    android:foregroundServiceType="connectedDevice" android:stopWithTask="false" />
```

Location is capped at `maxSdkVersion="30"` and `BLUETOOTH_SCAN` is flagged `neverForLocation`, so on
Android 12 and later **no location permission is requested at all**. A location prompt on a research
app is a consent and app-review liability this module does not need.

Two things remain the app's job:

- **Request the runtime permissions.** `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE` and
  `BLUETOOTH_CONNECT` on API 31+; `ACCESS_FINE_LOCATION` on API 30 and below.
  `missingPlatformRequirements()` reports which are outstanding.
- **Consider `POST_NOTIFICATIONS`** on API 33+. Sensing runs without it, but the foreground-service
  notification is hidden, which most ethics boards will not accept.

Minimum supported API is 24.

### iOS — manual, and silent if you get it wrong

iOS has no equivalent of manifest merging: `Info.plist` keys must be in the app target, and no
plugin can contribute them. **Copy the following verbatim** into `ios/Runner/Info.plist`.

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Detects nearby devices taking part in this study, so that time spent close to other participants can be measured. No location data is recorded.</string>

<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
    <string>bluetooth-peripheral</string>
</array>
```

The usage string is deliberately written to cover *any* study that uses proximity, not one
particular protocol, so it does not have to be re-approved per study. It is accurate as written: the
module records a peer pseudonym and a signal strength, and never a location.

`NSBluetoothPeripheralUsageDescription` is only needed below iOS 13, and this plugin requires iOS 13
or later.

**Do not add `location` to `UIBackgroundModes`.** Herald ships a CoreLocation mobility sensor that
is *enabled by default* and switches on background location updates, which aborts the app on launch
with `Invalid parameter not satisfying: !stayUp || CLClientIsBackgroundable(...)`. The background
mode it is asking for would silence that and start collecting location, contradicting the usage
string above. `ProximitySensor` disables the sensor instead:

```swift
BLESensorConfiguration.mobilitySensorEnabled = nil
```

Herald for Android has no such sensor, which is why this is an iOS-only trap and why the Android
side reached the same privacy position without needing anything switched off.

Omitting any of the above does **not** produce a crash. The app simply stops sensing when the screen
locks, and the study discovers it at analysis time. Because that failure is invisible, `start()`
refuses to run and reports what is missing:

```dart
final missing = await ProximityPlatform.instance.missingPlatformRequirements();
if (missing.isNotEmpty) throw StateError(missing.join('; '));
```

## What goes on the air

18 bytes, per [the wire contract](../../contracts/wire/proximity_payload/1.0.0.md):

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | `format_version`, currently `1` |
| 1 | 16 | pseudonym, as a canonical lowercase UUID |
| 17 | 1 | device class: `0` iOS, `1` Android, `255` unknown |

Nothing else. No epidemiological state, no study identifier, no timestamp, no sequence number. The
Epigames payload this replaces was 28 bytes and carried simulated infection state; those fields are
specific to that game and were removed rather than zeroed, so the two formats are not interoperable
and are not intended to be.

The study is not named on the wire because it does not need to be — devices in different studies use
different BLE service UUIDs and never discover each other. Naming it would make study membership
observable to any passive listener, for no gain.

Device class is transmitted rather than inferred because the RSSI-to-distance mapping is
hardware-dependent and a receiver cannot reliably determine the sender's platform.

**Readers must ignore trailing bytes.** This is the one rule that could not be added later: it lets a
future version append fields — an opaque application extension, say — while already-deployed builds
keep detecting updated ones. A reader that rejected unexpected length would turn every future format
change into a fleet-wide detection outage that looks exactly like a quiet week.

## Using it

Study scoping comes first. Derive the service UUID from the study identifier, so two studies cannot
collide and no registry is needed:

```dart
final config = ProximityConfig(
  pseudonym: participantPseudonym,          // canonical UUID; sent as 16 bytes
  serviceUuid: studyServiceUuid(studyId),   // RFC 4122 v5, deterministic
  notification: ForegroundNotification(     // Android only; wording from the bundle
    title: bundle.proximityNotificationTitle,
    body: bundle.proximityNotificationBody,
  ),
);
```

Then wire the sensor to the aggregator. `events` is a sealed union, so the compiler makes you decide
what to do about lost detections rather than letting them pass unnoticed:

```dart
final aggregator = EpisodeAggregator(
  selfPseudonym: participantPseudonym,
  observerDeviceClass: await ProximityPlatform.instance.observerDeviceClass(),
  config: AggregatorConfig.fromBundle(bundle),
  store: coreOpenEpisodeStore,
);
await aggregator.restore();

ProximityPlatform.instance.events.listen((event) async {
  switch (event) {
    case ProximityDetection():
      for (final episode in aggregator.add(event)) {
        await core.record(
          module: 'proximity',
          schemaUri: contactEpisodeSchemaUri,
          observedAt: episode.endedAt,
          payload: episode.toPayload(),
        );
      }
      await aggregator.checkpoint();

    case ProximityDetectionsDropped(:final count):
      // Not a log line. Loss here lands on unattended background encounters, which are the
      // long ones, so it belongs in the record.
      await core.recordModuleHealth(module: 'proximity', droppedDetections: count);

    case ProximitySensingStarted():
      break;
  }
});

await ProximityPlatform.instance.start(config);
```

An encounter ends by an *absence* of sightings, which no event can announce, so the host must also
tick the aggregator on a timer:

```dart
Timer.periodic(const Duration(minutes: 1), (_) async {
  for (final episode in aggregator.tick(DateTime.now().toUtc())) {
    // record as above
  }
  await aggregator.checkpoint();
});
```

## Configuration comes from the study, not the build

`AggregatorConfig.fromModuleConfig` reads the study bundle's `proximity` module block. Two studies
with opposite minimisation rules run on the same signed binary:

```yaml
modules:
  proximity:
    on_device:
      max_episode_seconds: 900
      max_gap_seconds: 600
      sample_credit_seconds: 90
      dropout_threshold_seconds: 75
      include_rssi: false          # drop the calibration detail
      include_pair_key: false      # no cross-participant reconciliation
      include_min_distance: false
      include_device_class: true
    upload:
      min_duration_seconds: 60     # ignore passing contacts
      min_sample_count: 3
```

## The three time thresholds

Aggregation turns instants into durations, and every threshold below exists to keep that step
honest.

| Threshold | Default | What it decides |
| --- | --- | --- |
| `sampleCredit` | 90 s | The most observation time one sighting may vouch for. Time beyond it is bridged but credited to no band. |
| `dropoutThreshold` | 75 s | A longer silence is recorded in `gap_count`, whether or not time was lost. |
| `maxGap` | 600 s | A longer silence ends the encounter rather than being bridged. |
| `maxEpisode` | 900 s | Longer encounters are cut here and marked `truncated`. |

`sampleCredit` is the important one. A sighting is evidence about a single instant; treating a
ten-minute silence as ten minutes of proximity would manufacture exactly the sustained-contact
signal a transmission study is looking for. The invariant the tests enforce is that **band seconds
never sum to more than the elapsed time**.

Separating `dropoutThreshold` from `sampleCredit` lets a payload state *a dropout happened* and *no
time was lost* at once, which are different reliability facts.

## Why the epidemiology lives in Dart

Epigames estimated distance natively, in Swift and Kotlin. Here the native layer does one thing —
advertise, scan, and report `(peer, rssi, timestamp, device class)` — and everything downstream runs
in Dart:

```
native scan ──► ProximityDetection ──► DistanceEstimator ──► EpisodeAggregator ──► ContactEpisode
  Herald          platform interface       median+Kalman         time-in-band          payload
```

Distance banding and episode assembly are where the measurement is actually made, so they belong
where they can be run exhaustively in CI against synthetic streams. It also means one implementation
to get right instead of two.

Timestamps are stamped natively at the moment of measurement, not on arrival in Dart: iOS batches
background delivery, and an aggregator that credited observation time from arrival times would
misattribute exactly the long background encounters that matter most.

## In-flight episodes are persisted

An episode exists only in memory until proximity ends, so a process kill during a long encounter
would discard it — and that loss is not random. It falls preferentially on the longest encounters,
skewing precisely the tail of the contact-duration distribution the study exists to measure.
`OpenEpisodeStore` makes in-flight state durable; `epidemica_core` supplies the SQLite-backed
implementation, and `InMemoryOpenEpisodeStore` covers tests.

Detections observed while Dart is detached — after an iOS background relaunch, for instance — are
buffered natively and replayed on attach. Overflow is counted and reported as
`ProximityDetectionsDropped` rather than swallowed.

## Testing

Four suites, none of which need a radio.

```sh
# Dart: aggregation, banding, configuration, persistence   (34 tests)
cd packages/epidemica_proximity && flutter test

# Swift: the wire codec, no Xcode project needed            (6 tests)
cd packages/epidemica_proximity_ios/ios/epidemica_proximity_ios/wire && swift test

# Kotlin: the wire codec and the detection buffer          (10 tests)
cd packages/epidemica_proximity/example/android \
  && ./gradlew :epidemica_proximity_android:testDebugUnitTest

# Cross-language: the generated episode fixtures still validate
cd analysis && uv run pytest -q
cd server && mix test
```

Two things make these worth more than their count.

**The wire vectors are shared.** Kotlin and Swift decode the same
[`1.0.0.vectors.json`](../../contracts/wire/proximity_payload/1.0.0.vectors.json), including the
cases that must be rejected and the trailing-byte case that must not be. Two implementations that
can only meet on real hardware are otherwise free to disagree about byte order or trailing data, and
the symptom is two phones side by side detecting nothing, with no error anywhere.

**The episode fixtures are generated.** They come from real aggregator runs, so they cannot drift
into describing a payload the module never emits, and the same file is validated against the JSON
Schema by the Python and Elixir suites. To regenerate after an intentional behaviour change:

```sh
EPIDEMICA_WRITE_FIXTURES=1 flutter test test/fixture_reproduction_test.dart
```

Then re-run `analysis/` and `server/` to confirm the new payloads still validate in both languages.

## To do

**Needs two devices in a room** — the remaining W1 acceptance criteria:

- An iOS and an Android device discovering each other within 30 s.
- Detections continuing with the app backgrounded for ≥ 30 minutes on both platforms.
- iOS relaunch via BLE state restoration resuming with no user interaction. The stale-`sensorArray`
  handling is ported from Epigames and is hard-won; it must not regress.
- Confirming Herald 2.2.0 compiles under Xcode 26. SPM resolution is verified, but SwiftPM cannot
  cross-compile UIKit from the command line, so only an app build settles it. If it fails, the
  CocoaPods path is the fallback.
- Whether 90 s of sample credit matches Herald's real detection cadence on each platform, and
  whether an episode interrupted by process death should reopen or close out as `truncated`.

**Known risks**

- **Herald is unmaintained.** v2.2.0 is the latest release on both platforms and the last commits are
  around three years old, with upstream testing claimed only to iOS 14.6 and Android 10. Confining it
  to the two platform packages is the mitigation, not a fix.
- **Flutter is deprecating Kotlin-applying plugins.** The Android build warns that plugins applying
  the Kotlin Gradle Plugin will eventually fail. Herald for Android and the Epigames integration are
  both pure Java, so rewriting these ~300 lines in Java would retire the warning and a toolchain
  dependency together.

**Deferred by decision**

- **Rotating BLE identifiers.** The pseudonym is currently broadcast unchanged, which makes a device
  trackable by any passive listener for the duration of a study. This is why M1 is an internal pilot
  only: it would not pass a German DPIA or an Oxford cohort review.
- **An opaque application extension** in the payload, so an app such as Epigames can carry its own
  fields without forking the module. The wire format already tolerates trailing bytes, which is the
  part that had to be decided early; the extension itself can wait until something needs it.
- **A `module_health` observation contract** for dropped detections. The count reaches Dart today,
  but there is nowhere in the record to put it until `epidemica_core` defines one.
- **The SQLite `OpenEpisodeStore`**, which arrives with `epidemica_core` since that package owns the
  database.
