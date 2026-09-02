defmodule EpidemicaServerWeb.GzipBodyReader do
  @moduledoc """
  Transparently decompresses `Content-Encoding: gzip` request bodies for `Plug.Parsers`.

  Clients gzip their batches because the envelope repeats `study_id`, `device_id` and
  `protocol_hash` on every observation (ADR-0002 chose a uniform per-observation shape and relies on
  compression to absorb the repetition). Plug has no built-in support for compressed request bodies.

  An oversized body still returns `{:more, ...}`, which `Plug.Parsers` turns into a 413 — the
  behaviour the ingest contract specifies. Decompression is deliberately not attempted on a partial
  body, since a gzip stream cannot be decoded piecemeal here.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, maybe_gunzip(conn, body), conn}
      other -> other
    end
  end

  defp maybe_gunzip(conn, body) do
    if gzip?(conn) and body != "" do
      try do
        :zlib.gunzip(body)
      rescue
        # A body that claims to be gzip but is not is a client bug. Passing the bytes through lets
        # the JSON parser produce a 400 rather than a 500 from an unhandled zlib error.
        _ -> body
      end
    else
      body
    end
  end

  defp gzip?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-encoding")
    |> Enum.any?(&(String.downcase(&1) =~ "gzip"))
  end
end
