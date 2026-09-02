# Running an Epidemica study

Two axes, kept apart because they vary independently: **where the server runs**, and **which study
it serves**.

| where | |
|---|---|
| [`local/`](local) | A laptop and some phones in a room. Per-study recipes, because a game needs a schedule and a simulation environment that a collection pilot does not. |
| [`docker/`](docker) | The server image. Used by both a self-hosted deployment and the AWS one. |
| [`aws/`](aws) | Running that image on EC2, for studies that need a hosted server. |
| [`app-release/`](app-release) | Signed app builds pointed at a deployed server. |

[`common.sh`](common.sh) holds what the local recipes share: starting PostgreSQL, migrating,
working out this machine's LAN address, and registering a bundle.

**Self-hosting is the priority.** The AWS path deliberately runs the same container an institution
would run on its own hardware rather than a cloud-native architecture, so there is one artefact to
keep working rather than two that drift.

## The one thing that catches people out

Phones cannot reach `localhost`, and they will not accept plain HTTP outside a debug build.

The server hands the app an absolute `protocol_url` pointing at itself, and the app fetches that
URL directly. If the server advertises a name the phone cannot resolve, enrolment **succeeds**, the
bundle fetch fails, and the app refuses the study without the server ever logging an error. Locally
this is why `up.sh` derives the LAN address from the routing table; in a deployment it is why
`PHX_HOST` must be the public DNS name exactly as the app was built to reach it.

Every phone must be on the same network as the machine for a local run. Guest wifi with client
isolation will not work.

## Known gaps

- **Ticks are not scheduled.** A deployed study collects data and never advances until something
  drives the days. See [`tasks/backlog/0002`](../tasks/backlog/0002-scheduled-ticks.md); the AWS
  page has an interim cron entry.
- **Nothing here has been run end to end.** The image builds are written against the code but
  untested, and the five device-level criteria from M1 are still outstanding.
