#!/usr/bin/env bash
#
# Brings up a local Epidemica study server and registers an Epigame study. It does not tick: days
# are advanced by hand with `mix epidemica.tick`, which is deliberate while nothing schedules them.
#
# Unlike contactlog, this study has a schedule: day 1 begins at the instant the bundle names, and
# there is no day 8. START= overrides it, which is how you run the game today instead of on the
# date committed to the repository.
#
#   START=2026-09-07T06:00:00Z deploy/local/epigames/up.sh
#   TODAY=1 deploy/local/epigames/up.sh     # start at the top of the current hour
#
# A join code belongs to one study, and changing START changes the bundle's bytes and so registers a
# different one. Re-seeding therefore refuses rather than leaving the code pointing at the previous
# study, which is a phone joining a game that started yesterday. STEAL_CODE= moves it:
#
#   STEAL_CODE=1 START=... deploy/local/epigames/up.sh
#
# BUNDLE= registers a different study. The compressed one turns a seven-day game into seven
# five-minute rounds, which is what makes manual debugging possible at all:
#
#   START="$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)" \
#     BUNDLE=studies/epigame-debug/bundle.json deploy/local/epigames/up.sh
#
# After the first run, add STEAL_CODE=1 to that: every new start time is a new study, and the code
# has to be told to follow.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../common.sh
source "$here/../../common.sh"

repo="$(cd "$here/../../.." && pwd)"
bundle="$(epidemica_bundle "${BUNDLE:-$repo/studies/epigame7/bundle.json}")"

if [[ -n "${TODAY:-}" ]]; then
  START="$(date -u +%Y-%m-%dT%H:00:00Z)"
  export START
fi

lan_ip="$(epidemica_lan_ip)"
export EPIDEMICA_HOST="$lan_ip"

epidemica_postgres
cd "$repo/server"
epidemica_migrate

echo "==> Checking the twin can run"
if ! (cd "$repo/models" && uv run python -c 'import starsim' >/dev/null 2>&1); then
  echo "The Starsim environment is not ready. Run: cd $repo/models && uv sync" >&2
  exit 1
fi

epidemica_seed "$bundle"

cat <<EOF

==> Server is at http://$lan_ip:4000

Build the app against it:

  cd $repo/apps/epigames
  flutter run --dart-define=EPIDEMICA_SERVER=http://$lan_ip:4000/v1/

The game advances once a day. Nothing is shown to a player until the first tick has
run, which is deliberate: an invented "you are healthy" is indistinguishable from a
computed one. To advance a day by hand:

  cd $repo/server && mix epidemica.tick --study <id> --day 1

Every phone must be on the same network as this machine.

EOF

exec mix phx.server
