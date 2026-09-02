#!/usr/bin/env bash
#
# Brings up a local Epidemica study server and registers the contactlog pilot.
#
# Phones cannot reach "localhost", so this binds to every interface and hands out absolute URLs
# containing this machine's LAN address. That address ends up inside protocol_url, which the app
# fetches directly — getting it wrong is the usual reason a field trial fails at enrolment.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
bundle="${BUNDLE:-$repo/studies/contactlog/bundle.json}"

# Ask the routing table which interface reaches the outside world, rather than guessing en0.
default_iface="$(route -n get default 2>/dev/null | awk '/interface: /{print $2}')"
lan_ip="${EPIDEMICA_HOST:-$(ipconfig getifaddr "${default_iface:-en0}" 2>/dev/null || true)}"

if [[ -z "$lan_ip" ]]; then
  echo "Could not determine this machine's LAN address." >&2
  echo "Set it explicitly:  EPIDEMICA_HOST=192.168.1.42 $0" >&2
  exit 1
fi

export EPIDEMICA_HOST="$lan_ip"

if ! pg_isready -q 2>/dev/null; then
  echo "==> Starting PostgreSQL"
  brew services start postgresql@14
  until pg_isready -q; do sleep 1; done
fi

cd "$repo/server"

echo "==> Dependencies"
mix deps.get >/dev/null

echo "==> Database"
mix ecto.create >/dev/null 2>&1 || true
mix ecto.migrate

echo "==> Registering $(basename "$(dirname "$bundle")")"
mix epidemica.seed_study --bundle "$bundle"

cat <<EOF

==> Server is at http://$lan_ip:4000

Build the app against it:

  cd $repo/apps/template
  flutter run --dart-define=EPIDEMICA_SERVER=http://$lan_ip:4000/v1/

Every phone must be on the same network as this machine. If enrolment fails but the
server logs nothing, that is almost always the reason.

EOF

exec mix phx.server
