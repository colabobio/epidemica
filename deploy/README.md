# deploy

One directory per study, because bringing up a study is not the same job for every study: a
collection pilot needs a server and a join code, and a game additionally needs a schedule, a
simulation environment and something to advance the days.

| | what it runs | app |
|---|---|---|
| [`contactlog/`](contactlog) | The M1 pilot: devices in a room producing a contact network | `apps/template` |
| [`epigames/`](epigames) | The seven-day game, with a twin and a score | `apps/epigames` |

[`common.sh`](common.sh) holds what they share: starting PostgreSQL, migrating, working out this
machine's LAN address, and registering a bundle.

## The one thing that catches people out

Phones cannot reach `localhost`. The server hands the app an absolute `protocol_url` pointing at
itself, and the app fetches that URL directly — so if the server advertises `localhost`, enrolment
succeeds, the bundle fetch fails, and the app refuses the study without the server ever logging an
error. Both scripts work out this machine's LAN address from the routing table and bind to every
interface to avoid exactly that.

Every phone must be on the same network. Guest wifi with client isolation will not work.
