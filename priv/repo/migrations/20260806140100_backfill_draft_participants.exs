defmodule SleeperPlayerApi.Repo.Migrations.BackfillDraftParticipants do
  @moduledoc """
  Production has ~3,400 `observed_picks` rows and an empty
  `draft_participants` table — nothing called `upsert_draft_participants/2`
  before this branch (see the report on this step). Once the participation
  queries (`Intel.manager_drafts_seen/0`, `Intel.manager_ids_for_league/2`,
  `Intel.manager_corpus_stats/1`) switch onto `draft_participants` instead of
  re-deriving from `observed_picks`, an unbackfilled table means every
  manager reads 0 drafts seen — silently zeroing the shrinkage weights and
  corrupting every survival number. This is mandatory, not optional.

  Delegates to `SleeperPlayerApi.Intel.backfill_draft_participants/0` rather
  than duplicating the derivation as raw SQL here, so there is exactly one
  place that knows how to turn `observed_picks` into participation rows.
  That function is itself idempotent (`upsert_draft_participants/2` is
  `on_conflict: :nothing` on `(draft_id, user_id)`), so this migration is
  safe to re-run if it's ever replayed.
  """
  use Ecto.Migration

  def up do
    SleeperPlayerApi.Intel.backfill_draft_participants()
  end

  def down do
    :ok
  end
end
