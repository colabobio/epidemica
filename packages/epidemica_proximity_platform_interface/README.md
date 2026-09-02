# epidemica_proximity_platform_interface

The boundary between Dart and the radio. Depended on by
[`epidemica_proximity`](../epidemica_proximity) and by every platform implementation, and by nothing
else.

Deliberately narrow: start, stop, and a stream of events. Everything epidemiological — smoothing,
banding, episode assembly, minimisation — lives in `epidemica_proximity`, where it runs in CI
without a device.

| Type | Purpose |
| --- | --- |
| `ProximityDetection` | One sighting: peer pseudonym, RSSI, natively stamped timestamp, device class. |
| `ProximitySensingStarted` | The sensor is running and the native buffer has drained. |
| `ProximityDetectionsDropped` | Detections were lost to buffer overflow. Reported, never swallowed. |
| `ProximityConfig` | Pseudonym, study service UUID, Android notification wording. |
| `ProximityPlatform` | What an implementation must provide. |
| `MethodChannelProximity` | The default implementation, shared by both platforms. |

`ProximityEvent` is a **sealed** union, so a consumer cannot quietly ignore dropped detections: the
compiler asks. That loss is not random — it lands on unattended background encounters, which are the
long ones a transmission study most wants to measure.

`MethodChannelProximity` lives here rather than being duplicated per platform because both platforms
speak an identical protocol. Duplicating it would let iOS and Android drift apart in Dart as well as
in native code, which is the failure the federated split exists to prevent.

## Implementing another platform

Register in place of the endorsed implementations — for dedicated BLE badges, a nationally mandated
stack, or a fake in tests:

```dart
class MyProximityPlatform extends ProximityPlatform { /* ... */ }

ProximityPlatform.instance = MyProximityPlatform();
```

The channel protocol an implementation must speak, if it uses one, is defined by
`MethodChannelProximity`: methods `start`, `stop`, `isRunning`, `observerDeviceClass`,
`missingPlatformRequirements`, and events tagged `detection`, `started` or `dropped`. Unknown event
tags are dropped rather than thrown on, so a newer native side talking to an older Dart side
degrades to missing diagnostics instead of a dead stream.
