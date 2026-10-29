defmodule Pinchflat.Repo.Migrations.MarkAgeRestrictedMedia do
  use Ecto.Migration

  # Age-restricted media can't be downloaded without cookies, but it used to be retried
  # on every index anyway, blocking the download queue. It's now marked `needs_auth`
  # (yt-dlp's name for it) and skipped unless its source uses cookies. This marks media
  # that has already failed that way so it stops being retried straight after upgrading.
  def change do
    execute(
      """
      UPDATE media_items SET availability = 'needs_auth'
      WHERE media_filepath IS NULL
        AND (availability IS NULL OR availability = 'public')
        AND last_error LIKE '%Sign in to confirm your age%'
      """,
      "SELECT 1"
    )
  end
end
