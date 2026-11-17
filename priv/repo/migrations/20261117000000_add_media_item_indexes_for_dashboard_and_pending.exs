defmodule Pinchflat.Repo.Migrations.AddMediaItemIndexesForDashboardAndPending do
  use Ecto.Migration

  # `media_items` rows are large (they hold each video's description), so any query that has
  # to read every row gets slow on big libraries and slow disks. These indexes let the
  # queries that run most often be answered without touching those rows:
  #
  #   * download stats: "how many items are downloaded, and how big are they?" for the
  #     home page and the per-source counts on the sources page
  #   * not downloaded: "what's still waiting to be downloaded?" for the home page's
  #     pending list. Only holds media without a file, so it stays tiny
  #
  # The plain `source_id` index is dropped because every multi-column index on this table
  # that starts with `source_id` already does its job. While it existed, SQLite sometimes
  # picked it over the better index and went back to reading every row of a source.
  def up do
    create_if_not_exists index(:media_items, [:source_id, :media_filepath, :media_size_bytes],
                           name: "media_items_download_stats_index"
                         )

    create_if_not_exists index(:media_items, [:id],
                           where: "media_filepath IS NULL",
                           name: "media_items_not_downloaded_index"
                         )

    drop_if_exists index(:media_items, [:source_id])
  end

  def down do
    create_if_not_exists index(:media_items, [:source_id])

    drop_if_exists index(:media_items, [:id], name: "media_items_not_downloaded_index")
    drop_if_exists index(:media_items, [:source_id], name: "media_items_download_stats_index")
  end
end
