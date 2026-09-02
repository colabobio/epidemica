# epidemica_proximity

Bluetooth proximity module for Epidemica. Turns peer sightings into **contact episodes**
— time spent in each distance band — and applies the study's minimisation rules before
anything reaches the outbox.

Payloads validate against
[`contracts/observations/proximity/contact_episode/1.0.0.json`](../../contracts/observations/proximity/contact_episode/1.0.0.json).

## Why the epidemiology lives in Dart

The Epigames app estimated distance natively, in Swift and Kotlin. Here the native layer
does one thing — advertise, scan, and report `(peer, rssi, timestamp, device class)` —
and everything downstream of that runs in Dart:

```
native scan ──► ProximityDetection ──► DistanceEstimator ──► EpisodeAggregator ──► ContactEpisode
   (W1)          platform interface        median+Kalman         time-in-band          payload
```

Distance banding and episode assembly are where the measurement is actually made, so they
belong where they can be run exhaustively in CI against synthetic streams. None of the
tests in this package need a radio, a device, or a second phone.

## The three time thresholds

Aggregation turns instants into durations, and every threshold below exists to keep that
step honest.

| Threshold | Default | What it decides |
| --- | --- | --- |
| `sampleCredit` | 90 s | The most observation time one sighting may vouch for. Time beyond it is bridged but credited to no band. |
| `dropoutThreshold` | 75 s | A longer silence is recorded in `gap_count`, whether or not time was lost. |
| `maxGap` | 600 s | A longer silence ends the encounter rather than being bridged. |
| `maxEpisode` | 900 s | Longer encounters are cut here and marked `truncated`. |

`sampleCredit` is the important one. A sighting is evidence about a single instant;
treating a ten-minute silence as ten minutes of proximity would manufacture exactly the
sustained-contact signal a transmission study is looking for. The invariant the tests
enforce is that **band seconds never sum to more than the elapsed time**.

## Configuration comes from the study, not the build

`AggregatorConfig.fromBundle` reads the protocol bundle's `proximity.on_device` and
`proximity.upload` blocks. Two studies with opposite minimisation rules run on the same
signed binary:

```yaml
proximity:
  on_device:
    max_episode_seconds: 900
    include_rssi: false          # drop the calibration detail
    include_pair_key: false      # no cross-participant reconciliation
    include_min_distance: false
    include_device_class: true
  upload:
    min_duration_seconds: 60     # ignore passing contacts
    min_sample_count: 3
```

## In-flight episodes are persisted

An episode exists only in memory until proximity ends, so a process kill during a long
encounter would discard it — and that loss is not random. It falls preferentially on the
longest encounters, skewing precisely the tail of the contact-duration distribution the
study exists to measure. `OpenEpisodeStore` makes in-flight state durable;
`epidemica_core` supplies the SQLite-backed implementation, and
`InMemoryOpenEpisodeStore` covers tests.

```dart
final aggregator = EpisodeAggregator(
  selfPseudonym: pseudonym,
  observerDeviceClass: await ProximityPlatform.instance.observerDeviceClass(),
  config: AggregatorConfig.fromBundle(bundle),
  store: coreOpenEpisodeStore,
);
await aggregator.restore();

ProximityPlatform.instance.detections.listen((detection) async {
  for (final episode in aggregator.add(detection)) {
    await core.record(module: 'proximity', schema: contactEpisodeSchema,
                      observedAt: episode.endedAt, payload: episode.toPayload());
  }
  await aggregator.checkpoint();
});
```

## Tests

```sh
flutter test
```

The contact-episode fixtures are this package's golden file. They are **generated from
real aggregator runs**, so they cannot drift into describing a payload the module never
emits, and the same file is validated against the JSON Schema by the Python and Elixir
contract suites. To regenerate after an intentional behaviour change:

```sh
EPIDEMICA_WRITE_FIXTURES=1 flutter test test/fixture_reproduction_test.dart
```

Then re-run `analysis/` and `server/` to confirm the new payloads still validate in both
languages.

## Still to build

- **W1** — `epidemica_proximity_android` and `epidemica_proximity_ios`, the Herald-backed
  implementations of `ProximityPlatform`. Until one is registered,
  `ProximityPlatform.instance` throws.
- **W3** — the SQLite `OpenEpisodeStore` and the `epidemica_core` adapter sketched above.
