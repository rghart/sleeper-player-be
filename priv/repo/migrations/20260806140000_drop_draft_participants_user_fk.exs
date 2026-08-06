defmodule SleeperPlayerApi.Repo.Migrations.DropDraftParticipantsUserFk do
  @moduledoc """
  `draft_participants.user_id` was created with a foreign key to
  `sleeper_users(id)` (see `20260805215408_create_draft_participants.exs`),
  which was fine as long as nothing populated the table. Now that
  `CrawlLeaguemateDrafts` derives participants from every stored pick's
  `picked_by` (see `Intel.upsert_observed_picks/2`), that assumption breaks:
  `sleeper_users` only holds the ~13 leaguemates of *this* league (from
  `GET /league/:id/users`), but a leaguemate's *other* leagues' drafts are
  full of co-managers Sleeper never told us about via that call.
  `observed_picks.picked_by` already has no such constraint for exactly this
  reason — see its migration — and `draft_participants` needs to mirror that
  same "any observed Sleeper user id, tracked or not" scope, since
  `manager_drafts_seen/0` (and everything the plan's §4d shrinkage math
  reads from it) has always counted every observed `picked_by`, not just
  known leaguemates.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE draft_participants DROP CONSTRAINT draft_participants_user_id_fkey"
  end

  def down do
    execute """
    ALTER TABLE draft_participants
    ADD CONSTRAINT draft_participants_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES sleeper_users(id) ON DELETE CASCADE
    """
  end
end
