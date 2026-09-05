# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :epidemica_server,
  ecto_repos: [EpidemicaServer.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :epidemica_server, EpidemicaServerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EpidemicaServerWeb.ErrorHTML, json: EpidemicaServerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: EpidemicaServer.PubSub,
  live_view: [signing_salt: "J63O09m5"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  epidemica_server: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  epidemica_server: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# The twin queue runs one job at a time: a tick reads the state its predecessor wrote, so two of
# them for the same study must never overlap.
#
# Cron owns the decision to look at all, on the hour. `Twin.Scheduler` decides which days are
# actually due from that moment, so an hour's downtime is a delayed tick, not a missed one.
#
# Prod only. In dev and test a scheduler that fires on its own is the opposite of what debugging
# needs: `studies/epigame-debug` exists precisely so a day can be ticked by hand, inspected, and
# ticked again, and a job that fires while that is happening is not a safety net, it is an
# interference. Test mode disables Oban entirely; dev gets the queue without the cron.
oban_plugins =
  if config_env() == :prod do
    [
      {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
      {Oban.Plugins.Cron,
       crontab: [
         {"@hourly", EpidemicaServer.Twin.Scheduler}
       ]}
    ]
  else
    [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]
  end

config :epidemica_server, Oban,
  repo: EpidemicaServer.Repo,
  queues: [twin: 1],
  plugins: oban_plugins

# Where the Starsim bridge lives. Set explicitly so a release fails loudly rather than guessing a
# path and silently running nothing.
config :epidemica_server, :twin, models_dir: Path.expand("../../models", __DIR__)

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
