defmodule Pinchflat.Repo.Migrations.AddAvailabilityToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      # yt-dlp's `availability` field: public, unlisted, private, needs_auth,
      # subscriber_only (channel members), premium_only. NULL means unknown.
      add :availability, :string
    end

    alter table(:sources) do
      # When false, members-only (subscriber_only) media is indexed but not downloaded.
      # Flip it on once you've joined the channel and provided cookies.
      add :download_members_only, :boolean, null: false, default: false
    end

    # Backfill: anything that has already failed with a members-only error is
    # members-only, so it stops being retried straight away after upgrading.
    execute(
      """
      UPDATE media_items SET availability = 'subscriber_only'
      WHERE media_filepath IS NULL AND (
        last_error LIKE '%available to this channel''s members%' OR
        last_error LIKE '%members-only content%'
      )
      """,
      "SELECT 1"
    )
  end
end
