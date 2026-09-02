defmodule EpidemicaServer.Twin.Runner do
  @moduledoc """
  The boundary between Elixir and the transmission engine.

  A tick is a batch job, so it runs as a subprocess rather than a service: nothing to supervise,
  no RPC failure modes, and re-running the exact same command against the exact same input file is
  the whole reproducibility story. The input is written to a file rather than piped so that a tick
  which went wrong can be replayed by hand.
  """

  require Logger

  @callback run(map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Run one tick document through the engine.

  Returns `{:error, {:engine_failed, status, stderr}}` rather than raising, because a failed tick
  must leave the study untouched and be retried, not take the queue down with it.
  """
  def run(doc) when is_map(doc) do
    impl().run(doc)
  end

  defp impl, do: Application.get_env(:epidemica_server, :twin_runner, __MODULE__.Subprocess)

  defmodule Subprocess do
    @moduledoc false
    @behaviour EpidemicaServer.Twin.Runner

    @impl true
    def run(doc) do
      path = Path.join(System.tmp_dir!(), "twin-#{Ecto.UUID.generate()}.json")

      try do
        File.write!(path, Jason.encode!(doc))

        case System.cmd(command(), args() ++ [path], cd: models_dir(), stderr_to_stdout: false) do
          {stdout, 0} -> decode(stdout)
          {_, status} -> {:error, {:engine_failed, status}}
        end
      rescue
        error -> {:error, {:engine_unavailable, Exception.message(error)}}
      after
        File.rm(path)
      end
    end

    defp decode(stdout) do
      case Jason.decode(stdout) do
        {:ok, outputs} -> {:ok, outputs}
        {:error, _} -> {:error, {:engine_output_unreadable, String.slice(stdout, 0, 500)}}
      end
    end

    defp config, do: Application.get_env(:epidemica_server, :twin, [])
    defp command, do: Keyword.get(config(), :command, "uv")
    defp args, do: Keyword.get(config(), :args, ~w(run python -m starsim_epidemica.twin))

    defp models_dir do
      Keyword.get(config(), :models_dir) ||
        raise "config :epidemica_server, :twin, models_dir: ... is not set"
    end
  end
end
