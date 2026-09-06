#!/usr/bin/env bash
#
# Brings up a local Epidemica study server and registers the contactlog pilot.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../common.sh
source "$here/../../common.sh"

repo="$(cd "$here/../../.." && pwd)"
bundle="$(epidemica_bundle "${BUNDLE:-$repo/studies/contactlog/bundle.json}")"

lan_ip="$(epidemica_lan_ip)"
export EPIDEMICA_HOST="$lan_ip"

epidemica_postgres
cd "$repo/server"
epidemica_migrate
epidemica_seed "$bundle"

cat <<EOF

==> Server is at http://$lan_ip:4000

Build the app against it:

  cd $repo/apps/template
  flutter run --dart-define=EPIDEMICA_SERVER=http://$lan_ip:4000/v1/

Every phone must be on the same network as this machine. If enrollment fails but the
server logs nothing, that is almost always the reason.

EOF

exec mix phx.server
