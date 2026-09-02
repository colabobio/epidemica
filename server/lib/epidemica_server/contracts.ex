defmodule EpidemicaServer.Contracts do
  @moduledoc """
  Validators generated at compile time from the schemas in `contracts/`.

  Exonerate compiles each schema into Elixir functions, which is fast but means the release can only
  validate schemas it was built with. That constraint is not a limitation to work around — it is
  exactly the ingest design in ADR-0002: an observation whose `schema_uri` this build does not know
  is stored with `validated: false` and re-validated after the server is upgraded, rather than
  rejected and lost.
  """

  require Exonerate

  # Paths are written as literals relative to the Mix project root. Exonerate's
  # `function_from_file/3` reads the file during macro expansion and does not expand module
  # attributes or function calls, so a computed path cannot be used here.
  @external_resource "../contracts/observations/envelope/1.0.0.json"
  @external_resource "../contracts/observations/proximity/contact_episode/1.0.0.json"
  @external_resource "../contracts/observations/location/location_fix/1.0.0.json"
  @external_resource "../contracts/observations/instruments/survey_response/1.0.0.json"

  Exonerate.function_from_file(
    :def,
    :validate_envelope,
    "../contracts/observations/envelope/1.0.0.json"
  )

  Exonerate.function_from_file(
    :def,
    :validate_contact_episode,
    "../contracts/observations/proximity/contact_episode/1.0.0.json"
  )

  Exonerate.function_from_file(
    :def,
    :validate_location_fix,
    "../contracts/observations/location/location_fix/1.0.0.json"
  )

  Exonerate.function_from_file(
    :def,
    :validate_survey_response,
    "../contracts/observations/instruments/survey_response/1.0.0.json"
  )

  @base "https://schemas.epidemica.info/observations/"

  @payload_validators %{
    @base <> "proximity/contact_episode/1.0.0.json" => :validate_contact_episode,
    @base <> "location/location_fix/1.0.0.json" => :validate_location_fix,
    @base <> "instruments/survey_response/1.0.0.json" => :validate_survey_response
  }

  @doc "Schema URIs this build can validate."
  def known_payload_schemas, do: Map.keys(@payload_validators)

  @doc "Envelope versions this build can validate, as reported by /health."
  def envelope_versions, do: ["1.0"]

  @doc """
  Validate a payload against the contract named by `schema_uri`.

  Returns `:ok`, `{:error, reason}`, or `{:error, :unknown_payload_schema}` when this build was not
  compiled with that schema.
  """
  def validate_payload(schema_uri, payload) do
    case Map.fetch(@payload_validators, schema_uri) do
      {:ok, fun} -> apply(__MODULE__, fun, [payload])
      :error -> {:error, :unknown_payload_schema}
    end
  end
end
