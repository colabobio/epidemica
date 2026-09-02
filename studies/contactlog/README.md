# studies/contactlog

The M1 pilot study: five devices in a room for an hour, producing a contact network.

**This directory contains no code, and that is the point.** It is a single
[`bundle.json`](bundle.json) validated against
[`contracts/bundle/1.0.0.json`](../../contracts/bundle/1.0.0.json). If this milestone could not be
completed without study-specific Dart, Tier 1 would not work as described and
[ADR-0001](../../docs/adr/0001-monorepo-and-package-boundaries.md) would need revisiting.

## What a researcher authors

The bundle names the modules the study uses and configures each of them. Declaring a module and
configuring it are the same act, so a bundle cannot name a module it forgot to configure, or
configure one it never declared.

`contactlog` asks for one module, `proximity`, and keeps everything it offers: RSSI summaries for
estimator calibration, closest approach, pair keys so the two halves of an encounter can be
reconciled, and both device classes. A minimal-collection study would switch those off in the same
file, and the same signed binary would then produce smaller payloads with no rebuild.

## Why the settings are what they are

`min_duration_seconds: 0` and `min_sample_count: 1` keep every episode, including brief ones. That
is right for a one-hour pilot whose purpose is to check the pipeline end to end — discarding short
contacts would hide exactly the wiring faults the pilot exists to find. A real transmission study
would raise both.

`max_episode_seconds: 900` bounds how much apportionment a simulation has to do when replaying an
episode into a timestep.

## Deploying it

The bundle is served over HTTPS at a stable URL and registered with the server against a join code.
Enrolment returns that URL together with the bundle's `sha256`, the app verifies the bytes it
fetches against that hash, and the hash is stamped on every observation — so a dataset always says
which configuration produced it.

Changing the bundle changes its hash, which is what makes a mid-study configuration change visible
in the data rather than silent.

## Limitation of this pilot

The proximity module currently broadcasts a fixed pseudonym, so a passive listener could track a
device for the duration of the study. That is why `contactlog` is an internal pilot: it would not
pass a German DPIA or an Oxford cohort review. Rotating identifiers are on the deferred register in
the [M1 plan](../../docs/milestones/m1-contact-logging.md).
