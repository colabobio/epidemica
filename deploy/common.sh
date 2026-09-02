#!/usr/bin/env bash
#
# Shared plumbing for bringing up a local study server.
#
# Phones cannot reach "localhost", so this binds to every interface and hands out absolute URLs
# containing this machine's LAN address. That address ends up inside protocol_url, which the app
# fetches directly — getting it wrong is the usual reason a field trial fails at enrolment.

set -euo pipefail

epidemica_repo() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

# Ask the routing table which interface reaches the outside world, rather than guessing en0.
epidemica_lan_ip() {
  local default_iface
  default_iface="$(route -n get default 2>/dev/null | awk '/interface: /{print $2}')"
  local ip="${EPIDEMICA_HOST:-$(ipconfig getifaddr "${default_iface:-en0}" 2>/dev/null || true)}"

  if [[ -z "$ip" ]]; then
    echo "Could not determine this machine's LAN address." >&2
    echo "Set it explicitly:  EPIDEMICA_HOST=192.168.1.42 $0" >&2
    exit 1
  fi
  echo "$ip"
}

epidemica_postgres() {
  if ! pg_isready -q 2>/dev/null; then
    echo "==> Starting PostgreSQL"
    brew services start postgresql@14
    until pg_isready -q; do sleep 1; done
  fi
}

epidemica_migrate() {
  echo "==> Dependencies"
  mix deps.get >/dev/null

  echo "==> Database"
  mix ecto.create >/dev/null 2>&1 || true
  mix ecto.migrate
}

# Registers a bundle, optionally rewriting its start time first.
#
# The schedule is part of the protocol, so changing it changes the bundle's hash — which is correct:
# a study that starts on a different day is a different study. Rather than edit the file in the
# repository before every run, START= writes a dated copy and registers that, leaving the served
# bytes and their hash consistent with each other.
epidemica_seed() {
  local bundle="$1"
  local start="${START:-}"

  if [[ -n "$start" ]]; then
    local dated="${TMPDIR:-/tmp}/epidemica-bundle-$$.json"
    python3 - "$bundle" "$start" "$dated" <<'PY'
import json, sys
src, start, dest = sys.argv[1:4]
bundle = json.load(open(src))
if "schedule" not in bundle:
    raise SystemExit(f"{src} has no schedule block; START= has nothing to set")
bundle["schedule"]["starts_at"] = start
with open(dest, "w") as handle:
    json.dump(bundle, handle, indent=2)
    handle.write("\n")
PY
    echo "==> Start time set to $start"
    bundle="$dated"
  fi

  echo "==> Registering $(basename "$(dirname "$1")")"
  mix epidemica.seed_study --bundle "$bundle"
}
