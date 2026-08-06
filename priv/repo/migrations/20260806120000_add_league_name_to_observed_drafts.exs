defmodule SleeperPlayerApi.Repo.Migrations.AddLeagueNameToObservedDrafts do
  use Ecto.Migration

  @moduledoc """
  `/availability` (plan §3f step 4) needs a human-readable league name for
  the response's top-level `league` field
  (`src/Prototypes/rankListIntel/fixture.json`'s `"league": "District 13
  Dynasty League"`), and nothing in the §3a schema stores one. Sleeper's own
  `/draft/:id` payload carries it at `metadata.name` (verified against the
  corpus fixtures — a draft's own metadata mirrors its league's display
  name), so it's cheap to capture at crawl time instead of an extra live
  `GET /league/:id` call on every `/availability` request.
  """

  def change do
    alter table(:observed_drafts) do
      add :league_name, :string
    end
  end
end
