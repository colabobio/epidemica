defmodule EpidemicaServer.Enrollment do
  @moduledoc """
  Joining a study and authenticating a device.

  Tokens are opaque random bytes. The raw value is returned to the client once and never stored;
  only its SHA-256 hash is kept, so a leaked database yields no usable participant credentials.
  """

  import Ecto.Query

  require Logger

  alias EpidemicaServer.Enrollment.{Device, Participant, Token}
  alias EpidemicaServer.Epigame.Rules
  alias EpidemicaServer.Ingest.Auth
  alias EpidemicaServer.{Repo, Studies}

  @access_ttl_days 30
  @refresh_ttl_days 365
  @token_bytes 32

  @doc """
  Join a study with a code.

  The client supplies its own `subject` pseudonym; the server binds a token to it. Generating it on
  the device is what allows a study to hold no participant identifier at all.

  Returns `{:ok, map}` with the tokens and the protocol the app should configure itself from, or
  `{:error, :no_such_study | :study_closed | :subject_taken | changeset}`.
  """
  def enroll(%{"join_code" => code, "subject" => subject, "device_id" => device_id} = attrs) do
    with {:ok, join_code} <- Studies.fetch_join_code(code),
         :ok <- ensure_open(join_code.study) do
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        with {:ok, participant} <- upsert_participant(join_code, subject, now),
             :ok <- ensure_device_available(participant, device_id, join_code.study_id),
             {:ok, device} <- upsert_device(participant, join_code.study_id, device_id, attrs),
             {:ok, access, refresh} <- issue_tokens(device, now) do
          publish_initial_state(join_code.study, participant)

          %{
            subject: participant.subject,
            study_id: join_code.study_id,
            arm: participant.arm,
            # When this participant joined, so anything scheduled from enrolment rather than from
            # the study's start has a moment to be measured against. A first survey that is about
            # the participant belongs to them, not to the calendar.
            enrolled_at: participant.enrolled_at,
            protocol_hash: join_code.study.protocol_hash,
            protocol_url: protocol_url(join_code.study_id),
            access_token: access,
            token_type: "Bearer",
            expires_in: @access_ttl_days * 24 * 3600,
            refresh_token: refresh,
            server_time: now
          }
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def enroll(_), do: {:error, :invalid_request}

  # A scored study publishes what the participant starts with, so the app has something true to show
  # before the first tick rather than a blank screen that reads as a broken study. A study with no
  # rules has no state to publish.
  #
  # Never fails an enrolment: being unable to publish an opening screen is not a reason to refuse
  # someone entry to the study. It is logged rather than dropped, because a study whose state
  # contract has drifted would otherwise show every participant a blank screen and report nothing.
  defp publish_initial_state(
         %{protocol: %{"rules" => %{"engine" => "epigame"}}} = study,
         participant
       ) do
    case EpidemicaServer.Epigame.publish_initial(study.id, participant.subject) do
      {:error, reason} ->
        Logger.warning(
          "could not publish initial state for #{participant.subject} " <>
            "in study #{study.id}: #{inspect(reason)}"
        )

      _ ->
        :ok
    end
  end

  defp publish_initial_state(_study, _participant), do: :ok

  defp ensure_open(%{status: "open"}), do: :ok
  defp ensure_open(_), do: {:error, :study_closed}

  # Re-enrolling with the same pseudonym is idempotent: a reinstall or a re-run of the join flow
  # should not create a second participant, and must not silently reassign the arm.
  defp upsert_participant(join_code, subject, now) do
    case Repo.get_by(Participant, study_id: join_code.study_id, subject: subject) do
      nil ->
        %Participant{}
        |> Participant.changeset(%{
          study_id: join_code.study_id,
          subject: subject,
          # A randomised study draws its arm here and keeps it. One stamped on the join code is the
          # other case: stratification by distribution channel, which is a different experiment.
          arm: arm_for(join_code, subject),
          enrolled_at: now
        })
        |> Repo.insert()

      existing ->
        {:ok, existing}
    end
  end

  defp arm_for(join_code, subject) do
    case Rules.arms(Map.get(join_code.study.protocol, "rules", %{})) do
      nil -> join_code.arm
      _arms -> Rules.assign_arm(join_code.study.protocol["rules"], join_code.study_id, subject)
    end
  end

  # A device_id belongs to one participant within a study. Allowing it to move would make the
  # observations already uploaded under it ambiguous.
  defp ensure_device_available(participant, device_id, study_id) do
    case Repo.get_by(Device, device_id: device_id, study_id: study_id) do
      nil -> :ok
      %{participant_id: id} when id == participant.id -> :ok
      _ -> {:error, :device_claimed}
    end
  end

  defp upsert_device(participant, study_id, device_id, attrs) do
    params = %{
      device_id: device_id,
      study_id: study_id,
      participant_id: participant.id,
      platform: attrs["platform"],
      app_version: attrs["app_version"],
      locale: attrs["locale"]
    }

    case Repo.get_by(Device, device_id: device_id, study_id: study_id) do
      nil -> %Device{} |> Device.changeset(params) |> Repo.insert()
      existing -> existing |> Device.changeset(params) |> Repo.update()
    end
  end

  defp issue_tokens(device, now) do
    with {:ok, access} <- create_token(device, "access", @access_ttl_days, now),
         {:ok, refresh} <- create_token(device, "refresh", @refresh_ttl_days, now) do
      {:ok, access, refresh}
    end
  end

  defp create_token(device, kind, ttl_days, now) do
    raw = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)

    %Token{}
    |> Token.changeset(%{
      device_row_id: device.id,
      kind: kind,
      token_hash: hash(raw),
      expires_at: DateTime.add(now, ttl_days * 24 * 3600, :second)
    })
    |> Repo.insert()
    |> case do
      {:ok, _} -> {:ok, raw}
      error -> error
    end
  end

  @doc """
  Resolve a presented access token to the device and study it authorises.

  Returns an `Ingest.Auth` so that everything downstream works from the token's binding rather than
  from anything the client asserted about itself.
  """
  def authenticate(raw_token) when is_binary(raw_token) do
    query =
      from t in Token,
        join: d in Device,
        on: d.id == t.device_row_id,
        join: p in Participant,
        on: p.id == d.participant_id,
        where: t.token_hash == ^hash(raw_token) and t.kind == "access",
        select: {t, d, p}

    case Repo.one(query) do
      nil ->
        {:error, :invalid_token}

      {token, device, participant} ->
        cond do
          token.revoked_at != nil ->
            {:error, :revoked}

          DateTime.compare(token.expires_at, DateTime.utc_now()) != :gt ->
            {:error, :expired}

          participant.withdrawn_at != nil ->
            {:error, :withdrawn}

          true ->
            {:ok,
             %Auth{
               study_id: device.study_id,
               device_id: device.device_id,
               subject: participant.subject
             }}
        end
    end
  end

  def authenticate(_), do: {:error, :invalid_token}

  @doc "Exchange a refresh token for a new access token, rotating the refresh token."
  def refresh(raw_refresh) when is_binary(raw_refresh) do
    query =
      from t in Token,
        join: d in Device,
        on: d.id == t.device_row_id,
        where: t.token_hash == ^hash(raw_refresh) and t.kind == "refresh",
        select: {t, d}

    case Repo.one(query) do
      nil ->
        {:error, :invalid_token}

      {token, device} ->
        now = DateTime.utc_now()

        cond do
          token.revoked_at != nil ->
            {:error, :revoked}

          DateTime.compare(token.expires_at, now) != :gt ->
            {:error, :expired}

          true ->
            Repo.transaction(fn ->
              # Rotate on use: a refresh token that has been replayed is evidence worth having, and
              # rotation bounds the damage from one that leaked.
              revoke_all(device, "access", now)
              Repo.update!(Token.changeset(token, %{revoked_at: now}))

              {:ok, access, refresh} = issue_tokens(device, now)

              %{
                access_token: access,
                token_type: "Bearer",
                expires_in: @access_ttl_days * 24 * 3600,
                refresh_token: refresh,
                server_time: now
              }
            end)
        end
    end
  end

  def refresh(_), do: {:error, :invalid_token}

  defp revoke_all(device, kind, now) do
    from(t in Token,
      where: t.device_row_id == ^device.id and t.kind == ^kind and is_nil(t.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: now])
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw)

  # Absolute, because the client fetches it directly. A relative path would work only for callers
  # that already knew where the server was, which the bundle URL exists to avoid assuming.
  defp protocol_url(study_id),
    do: EpidemicaServerWeb.Endpoint.url() <> "/v1/studies/#{study_id}/protocol"
end
