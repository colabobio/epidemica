# Building the apps for release

Producing signed binaries that talk to a deployed server. Covers `apps/epigames`; `apps/template`
is identical apart from the module set and the app name.

> **Two things are unfinished and will stop a release build.** Android signs with debug keys, and
> neither app declares the iOS Bluetooth keys the proximity plugin requires. Both are covered
> below. Neither has been exercised on a device — M1's five device-test criteria are still
> outstanding — so treat the first store build as new ground.

## The server URL is compiled in

```dart
const String _serverUrl = String.fromEnvironment(
  'EPIDEMICA_SERVER',
  defaultValue: 'http://10.0.2.2:4000/v1/',
);
```

Every build must pass `--dart-define=EPIDEMICA_SERVER=...`. **A release build that forgets it ships
with the Android-emulator loopback address**, which fails on a real device in a way that looks like
a network outage.

Two rules for the value:

- **It must be `https://`.** Android blocks cleartext from API 28 and iOS ATS blocks it. The
  laptop-and-LAN-address flow in [`../local`](../local) works only in debug builds.
- **It must match the server's `PHX_HOST` exactly.** The server hands the app an absolute
  `protocol_url` built from `PHX_HOST`; if the app reaches the server by one name and is told to
  fetch its protocol from another, enrollment succeeds and the bundle fetch fails with nothing
  logged server-side.

Include the trailing `/v1/`.

## iOS: declare what the plugin needs

Both apps now ship these keys, so there is nothing to add. They are recorded here because the
failure mode if they go missing is confusing: the app runs, senses nothing, and reports the
omission only through `missingPlatformRequirements`.

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Detects which other study participants are nearby, and for how long, so the study can
measure how contact patterns shape an outbreak. Your location is never recorded.</string>

<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
  <string>bluetooth-peripheral</string>
</array>
```

The usage description is shown verbatim in the permission prompt and is read by App Review. Say
what is collected and what is not; "this app uses Bluetooth" gets rejected and deserves to be.

Both background modes are needed: the module both scans (central) and advertises (peripheral), and
declaring one gives you an app that discovers others but is invisible to them — which produces a
contact network that reconciles to half the truth.

**Do not add `location` to `UIBackgroundModes`**, however tempting it looks when something crashes
asking for it. Herald enables a CoreLocation mobility sensor by default, and it aborts the app on
launch with

```
Invalid parameter not satisfying: !stayUp || CLClientIsBackgroundable(...)
```

The fix is to disable that sensor — `ProximitySensor.swift` sets
`BLESensorConfiguration.mobilitySensorEnabled = nil` — not to grant the background mode it is
asking for. Adding `location` silences the crash and starts collecting location, which contradicts
the sentence directly above it in the permission prompt.

Android needs nothing added. The plugin's own manifest is merged into the app, including
`neverForLocation` on `BLUETOOTH_SCAN`, which keeps a research app off the location permission
entirely on Android 12 and later. Herald for Android has no mobility sensor, which is why this
problem is iOS-only.

## Android: signing

`android/app/build.gradle.kts` currently says:

```kotlin
buildTypes {
    release {
        // TODO: Add your own signing config for the release build.
        signingConfig = signingConfigs.getByName("debug")
    }
}
```

Debug-signed builds cannot be uploaded to Play, and cannot be upgraded by a differently signed
build later. Generate a keystore once and **keep it for the life of the app** — losing it means a
new listing:

```sh
keytool -genkey -v -keystore ~/epidemica-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Create `apps/epigames/android/key.properties` — **untracked**, and confirm it is ignored before
committing anything:

```properties
storePassword=...
keyPassword=...
keyAlias=upload
storeFile=/absolute/path/to/epidemica-upload.jks
```

Then in `android/app/build.gradle.kts`, above `android {`:

```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
```

and inside `android { }`:

```kotlin
signingConfigs {
    create("release") {
        keyAlias = keystoreProperties["keyAlias"] as String
        keyPassword = keystoreProperties["keyPassword"] as String
        storeFile = keystoreProperties["storeFile"]?.let { file(it) }
        storePassword = keystoreProperties["storePassword"] as String
    }
}

buildTypes {
    release {
        signingConfig = signingConfigs.getByName("release")
    }
}
```

Consider Play App Signing, which holds the distribution key for you and makes an upload key
recoverable.

## Android: build

```sh
cd apps/epigames

flutter build appbundle --release \
  --dart-define=EPIDEMICA_SERVER=https://study.epidemica.info/v1/
```

Output: `build/app/outputs/bundle/release/app-release.aab`.

For sideloading onto study phones, an APK is easier:

```sh
flutter build apk --release \
  --dart-define=EPIDEMICA_SERVER=https://study.epidemica.info/v1/
```

Verify the URL actually made it in, because this is silent when wrong:

```sh
unzip -p build/app/outputs/flutter-apk/app-release.apk \
  assets/flutter_assets/NOTICES >/dev/null && echo "apk built"
strings build/app/outputs/flutter-apk/app-release.apk | grep -m1 'study.epidemica.info'
```

Set `versionCode`/`versionName` per release. Flutter takes them from `pubspec.yaml`'s
`version: 0.1.0+1` unless overridden with `--build-name`/`--build-number`; Play refuses a duplicate
`versionCode`.

## iOS: build

Requires a paid Apple Developer account and a Mac.

1. Open `apps/epigames/ios/Runner.xcworkspace` in Xcode.
2. Select the Runner target → Signing & Capabilities → your team. The bundle identifier is
   `info.epidemica.epidemicaEpigames`; change it to something you own before archiving.
3. Add the Info.plist keys above if you have not.
4. Set the deployment target. Herald is tested upstream only to iOS 14.6 and is unmaintained
   (see [ADR-0004](../../docs/adr)); 14.0 is the practical floor.

```sh
cd apps/epigames

flutter build ipa --release \
  --dart-define=EPIDEMICA_SERVER=https://study.epidemica.info/v1/ \
  --export-options-plist=ios/ExportOptions.plist
```

For a small study, TestFlight is usually the right distribution channel rather than the App Store:
it avoids a public listing for a study with a fixed cohort, and review is lighter. Either way,
expect questions about Bluetooth and background use — answer them with the study's information
screen, which already discloses the simulated participants.

## Before handing phones out

- [ ] The app reaches the server over HTTPS on a cellular connection, not just campus wifi
- [ ] enrollment with the real join code succeeds **and** the protocol bundle downloads —
      the second is what catches a `PHX_HOST` mismatch
- [ ] The permission prompts appear and their text reads sensibly
- [ ] Two phones discover each other and produce contact episodes in both directions; an asymmetry
      means one side's permission was declined or its radio is off
- [ ] Episodes reach the server: the pending count on the status screen falls to zero
- [ ] After the first tick, the state screen shows a colour, a score and a settlement that adds up
- [ ] The app survives being backgrounded for thirty minutes and keeps sensing

The last two are the M1 device criteria that remain outstanding, and they are the ones most likely
to fail on hardware nobody has tried yet.

## See also

- [`../aws`](../aws) — deploying the server these builds talk to
- [`../local`](../local) — the debug flow against a laptop
