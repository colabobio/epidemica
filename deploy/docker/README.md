# The server image

One image, used by both a self-hosted deployment and the AWS one. Keeping them the same is
deliberate: self-hosting is the priority, and a separate cloud-only artefact would drift until the
self-hosted path quietly stopped being the tested one.

| | |
|---|---|
| [`Dockerfile`](Dockerfile) | Elixir release **and** the Python environment the twin shells out to |
| [`docker-compose.yml`](docker-compose.yml) | Server, PostgreSQL, and Caddy for TLS |
| [`Caddyfile`](Caddyfile) | Automatic Let's Encrypt certificates |
| [`.env.example`](.env.example) | The three values that must be set |

```sh
cp .env.example .env   # fill it in
docker compose build
docker compose up -d db
docker compose run --rm server /app/bin/migrate
docker compose up -d
```

Build from the repository root; the compose file sets the context for you. Building from this
directory fails, because the image needs `contracts/` and `models/` as well as `server/`.

## Why Python is in here

The twin runs Starsim as a subprocess. Without it the server starts, serves enrolment, ingests
observations, and fails every tick with `{:engine_unavailable, ...}` — a study that collects
data and simulates nothing.

The environment is resolved at build time with `uv sync --frozen`. Frozen matters: a twin whose
Starsim version drifted between the image and `models/uv.lock` would produce results that no longer
reproduce, and reproducibility is the property every tick is stored to support.

At runtime the interpreter is named directly (`TWIN_COMMAND=/app/models/.venv/bin/python`) rather
than going through `uv`, so a tick cannot fail because a dependency resolver reached for the
network.

## Configuration

Read at runtime, so one image serves any deployment.

| | |
|---|---|
| `DATABASE_URL` | Required. `ecto://user:pass@host/db` |
| `SECRET_KEY_BASE` | Required. `mix phx.gen.secret` |
| `PHX_HOST` | Required in practice. The public name, which ends up inside every `protocol_url` |
| `PORT` | Defaults to 4000 |
| `POOL_SIZE` | Defaults to 10 |
| `MODELS_DIR` | Where `models/` lives in the image |
| `TWIN_COMMAND`, `TWIN_ARGS` | How to invoke the engine |

`PHX_HOST` is the one that bites. The server hands devices an absolute URL built from it, and the
app fetches that URL directly — so a wrong value produces successful enrolments followed by failed
bundle fetches, with nothing logged server-side.

## Checking the twin can run

The failure this image exists to prevent is silent, so test it explicitly rather than waiting for
the first tick:

```sh
docker compose exec server /app/models/.venv/bin/python -c 'import starsim; print(starsim.__version__)'
```
