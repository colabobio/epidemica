import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :epidemica_server, EpidemicaServer.Repo,
  username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
  password: System.get_env("PGPASSWORD") || "",
  hostname: System.get_env("PGHOST") || "localhost",
  database: "epidemica_server_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :epidemica_server, EpidemicaServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "8tuzELI0fSvZBn0yi7fR8/ISSXuQ6BhkhvfHr8YrUHYNpdsfoSZujXLjy6tqSO5L",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Tests drive ticks directly rather than waiting on a queue.
config :epidemica_server, Oban, testing: :manual

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
