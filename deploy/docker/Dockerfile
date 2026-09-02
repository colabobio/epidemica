# Epidemica study server.
#
# The unusual part: this image contains a Python environment as well as an Elixir release. The twin
# runs Starsim as a subprocess (`uv run python -m starsim_epidemica.twin`), so a server without
# Python compiles, boots, serves enrolments, ingests observations — and fails every tick with
# `{:engine_unavailable, ...}`. That failure surfaces as a study where nothing ever happens, so it
# is worth getting right before the first deployment rather than after.
#
# Build from the repository root, not from this directory:
#   docker build -f deploy/docker/Dockerfile -t epidemica-server .

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=28.0.1
ARG DEBIAN_VERSION=bookworm-20250630-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ---------------------------------------------------------------------------------------------
# Build the Elixir release
# ---------------------------------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV=prod

COPY server/mix.exs server/mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY server/config/config.exs server/config/${MIX_ENV}.exs config/
RUN mix deps.compile

# exonerate compiles the JSON Schemas into validator functions at build time, so the contracts must
# be present and at the path the server expects relative to itself.
COPY contracts ../contracts

COPY server/priv priv
COPY server/lib lib
COPY server/assets assets
RUN mix assets.deploy
RUN mix compile

COPY server/config/runtime.exs config/
COPY server/rel rel
RUN mix release

# ---------------------------------------------------------------------------------------------
# Runtime: the release, plus the Python the twin shells out to
# ---------------------------------------------------------------------------------------------
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# uv, pinned. The lockfile in models/ decides the Python and package versions; uv only has to be
# new enough to read it.
COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /usr/local/bin/uv

WORKDIR /app

# Resolved at build time so the first tick is not also the first dependency download. `--frozen`
# refuses to update the lockfile: a twin whose Starsim version drifted between the image and the
# repository would produce results that no longer reproduce.
COPY models /app/models
RUN cd /app/models && uv sync --frozen --no-dev

COPY --from=builder /app/_build/prod/rel/epidemica_server ./

# Name the interpreter directly rather than going through `uv` on every tick: the environment is
# already resolved, and a tick must not be able to fail because a resolver reached for the network.
ENV MODELS_DIR=/app/models
ENV TWIN_COMMAND=/app/models/.venv/bin/python
ENV TWIN_ARGS="-m starsim_epidemica.twin"
ENV PHX_SERVER=true
EXPOSE 4000

RUN useradd --create-home --uid 1000 epidemica \
  && chown -R epidemica:epidemica /app
USER epidemica

CMD ["/app/bin/server"]
