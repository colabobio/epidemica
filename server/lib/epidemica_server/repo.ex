defmodule EpidemicaServer.Repo do
  use Ecto.Repo,
    otp_app: :epidemica_server,
    adapter: Ecto.Adapters.Postgres
end
