#!/usr/bin/env bash
#
# Brings up a local Epidemica study server, registers the seven-day Epigame, and runs the daily
# ticks that make it a game rather than a data collection.
#
# Unlike contactlog, this study has a schedule: day 1 begins at the instant the bundle names, and
# there is no day 8. START= overrides it, which is how you run the game today instead of on the
# date committed to the repository.
#
#   START=2026-09-07T06:00:00Z deploy/local/epigames/up.sh
#   TODAY=1 deploy/local/epigames/up.sh     # start at the top of the current hour

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../common.sh
source "$here/../../common.sh"

repo="$(cd "$here/../../.." && pwd)"
bundle="${BUNDLE:-$repo/studies/epigame7/bundle.json}"

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
