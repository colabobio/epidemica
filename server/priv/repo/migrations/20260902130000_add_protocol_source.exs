defmodule EpidemicaServer.Repo.Migrations.AddProtocolSource do
  use Ecto.Migration

  def change do
    alter table(:studies) do
      # The exact bytes served to clients.
      #
      # Not a re-encoding of the decoded `protocol` map: two JSON documents that parse identically
      # can serialise differently, and the client verifies the bytes it receives against the hash
      # enrollment gave it. Storing the source is also what makes the hash identify the authored
      # artefact, so two institutions running the same study stamp the same protocol_hash.
      add :protocol_source, :text
    end
  end
end
