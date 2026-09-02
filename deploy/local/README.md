# Running a study on a laptop

A machine, some phones, and one room. One directory per study, because bringing a study up is not
the same job for every study: a collection pilot needs a server and a join code, and a game
additionally needs a schedule, a simulation environment and something to advance the days.

| | what it runs | app |
|---|---|---|
| [`contactlog/`](contactlog) | The M1 pilot: devices producing a contact network | `apps/template` |
| [`epigames/`](epigames) | The seven-day game, with a twin and a score | `apps/epigames` |

Both use plain HTTP against this machine's LAN address, which works only for debug builds. For
anything a participant keeps, see [`../aws`](../aws) and [`../app-release`](../app-release).
