defmodule Pinchflat.Media do
  @moduledoc """
  The Media context.
  """

  import Ecto.Query, warn: false
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Metadata.MediaMetadata

  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner

  # Some fields should only be set on insert and not on update.
  @fields_to_drop_on_update [:playlist_index]
  # For queries run by background jobs that walk a whole source. Nothing is waiting on them,
  # so they get far longer than the default before being abandoned.
  @background_query_timeout :timer.minutes(10)
  @active_job_states ~w(available scheduled retryable executing)

  @doc """
  Returns the list of media_items.

  Returns [%MediaItem{}, ...].
  """
  def list_media_items do
    Repo.all(MediaItem)
  end

  @doc """
  Returns a list of media_items that are upgradeable based on the redownload delay
  of the media_profile their source belongs to. In this context, upgradeable means
  that it's been long enough since upload that the video may be in a higher quality
  or have better sponsorblock segments (or similar).

  The logic is that a media_item is past_redownload_delay if the media_item's uploaded_at is
  at least redownload_delay_days ago AND `media_downloaded_at` - `redownload_delay_days`
  is before the media_item's `uploaded_at`.

  This logic grabs media that we've recently downloaded AND is recently uploaded, but
  doesn't grab media that we've recently downloaded and was uploaded a long time ago.
  This also makes things work as expected when downloading media from a source for the
  first time.

  Returns [%MediaItem{}, ...]
  """
  def list_upgradeable_media_items do
    # One query per source that can actually have upgradeable media, rather than one scan of
    # the whole library: profiles without a redownload delay (the default) are skipped
    # entirely, and each query only reads its own source's rows.
    upgradeable_source_ids =
      Repo.all(
        from(s in Source,
          join: mp in assoc(s, :media_profile),
          where: fragment("IFNULL(?, 0) > 0", mp.redownload_delay_days),
          order_by: s.id,
          select: s.id
        )
      )

    Enum.flat_map(upgradeable_source_ids, fn source_id ->
      MediaQuery.new()
      |> MediaQuery.require_assoc(:media_profile)
      |> where(^dynamic(^MediaQuery.for_source(source_id) and ^MediaQuery.upgradeable()))
      |> Repo.all(timeout: @background_query_timeout)
    end)
  end

  @doc """
  Returns a list of pending media_items for a given source, where
  pending means the media_item satisfies `MediaQuery.pending`. You
  should really check out that function if you need to know more
  because it has a lot going on.

  Options:
    - `:fields` - only load these fields (eg: `[:id]`). Pending lists can be thousands of
      rows long and callers that just enqueue jobs don't need titles, descriptions, etc.
    - `:without_active_job_for` - a worker module. Leaves out media items that already have
      a queued or running job for that worker.

  Returns [%MediaItem{}, ...].
  """
  def list_pending_media_items_for(%Source{} = source, opts \\ []) do
    from(mi in MediaItem, as: :media_item)
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending()))
    |> maybe_exclude_media_with_active_job(Keyword.get(opts, :without_active_job_for))
    |> maybe_select_fields(Keyword.get(opts, :fields))
    |> Repo.all()
  end

  @doc """
  For a given media_item, tells you if it is pending download. This is defined as
  the media_item satisfying `MediaQuery.pending` which you should really check out.

  Intentionally does not take the `download_media` setting of the source into account.

  Returns boolean()
  """
  def pending_download?(%MediaItem{} = media_item) do
    media_item = Repo.preload(media_item, source: :media_profile)

    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic([m, s, mp], m.id == ^media_item.id and ^MediaQuery.pending()))
    |> Repo.exists?()
  end

  @doc """
  Returns a list of media_items that match the search term. Adds a `matching_search_term`
  virtual field to the result set.

  Has explit handling for blank search terms because SQLite doesn't like empty MATCH clauses.

  Returns [%MediaItem{}, ...].
  """
  def search(_search_term, _opts \\ [])
  def search("", _opts), do: []
  def search(nil, _opts), do: []

  def search(search_term, opts) do
    limit = Keyword.get(opts, :limit, 50)

    MediaQuery.new()
    |> MediaQuery.matching_search_term(search_term)
    |> Repo.maybe_limit(limit)
    |> Repo.all()
  end

  @doc """
  Gets a single media_item.

  Returns %MediaItem{}. Raises `Ecto.NoResultsError` if the Media item does not exist.
  """
  def get_media_item!(id), do: Repo.get!(MediaItem, id)

  @doc """
  Creates a media_item.

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def create_media_item(attrs) do
    %MediaItem{}
    |> MediaItem.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a media item from the attributes returned by the video backend
  (read: yt-dlp).

  Unlike `create_media_item`, this will attempt an update if the media_item
  already exists. This is so that future indexing can pick up attributes that
  we may not have asked for in the past (eg: uploaded_at)

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def create_media_item_from_backend_attrs(source, media_attrs_struct) do
    attrs = Map.merge(%{source_id: source.id}, Map.from_struct(media_attrs_struct))

    %MediaItem{}
    |> MediaItem.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set:
          attrs
          |> Map.drop(@fields_to_drop_on_update)
          # yt-dlp doesn't always report availability. Don't let an unknown value
          # wipe out a known one (eg: members-only, learned from a failed download)
          |> then(fn a -> if is_nil(a[:availability]), do: Map.delete(a, :availability), else: a end)
          |> Map.to_list()
      ],
      conflict_target: [:source_id, :media_id]
    )
  end

  @doc """
  Updates a media_item.

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def update_media_item(%MediaItem{} = media_item, attrs) do
    update_attrs = Map.drop(attrs, @fields_to_drop_on_update)

    media_item
    |> MediaItem.changeset(update_attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a media_item, its associated tasks, and our internal metadata files.
  Can optionally delete the media_item's media files (media, thumbnail, subtitles, etc).

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_media_item(%MediaItem{} = media_item, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    Tasks.delete_tasks_for(media_item)

    if delete_files do
      {:ok, _} = do_delete_media_files(media_item)
      run_user_script(:media_deleted, media_item)
    end

    # Should delete these no matter what
    delete_internal_metadata_files(media_item)
    Repo.delete(media_item)
  end

  @doc """
  Deletes the tasks and media files associated with a media_item but leaves the
  media_item in the database. Does not delete anything to do with associated metadata.

  Optionally accepts a second argument `addl_attrs` which will be merged into the
  media_item before it is updated. Useful for setting things like `prevent_download`
  and `culled_at`, if wanted

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_media_files(%MediaItem{} = media_item, addl_attrs \\ %{}) do
    filepath_attrs = MediaItem.filepath_attribute_defaults()

    Tasks.delete_tasks_for(media_item)
    {:ok, _} = do_delete_media_files(media_item)
    run_user_script(:media_deleted, media_item)

    update_media_item(media_item, Map.merge(filepath_attrs, addl_attrs))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking media_item changes.
  """
  def change_media_item(%MediaItem{} = media_item, attrs \\ %{}) do
    MediaItem.changeset(media_item, attrs)
  end

  defp maybe_select_fields(query, nil), do: query
  defp maybe_select_fields(query, fields), do: select(query, [mi], struct(mi, ^fields))

  defp maybe_exclude_media_with_active_job(query, nil), do: query

  defp maybe_exclude_media_with_active_job(query, worker) do
    worker_name = Oban.Worker.to_string(worker)

    where(
      query,
      [mi],
      not exists(
        from(t in Tasks.Task,
          join: j in assoc(t, :job),
          where: t.media_item_id == parent_as(:media_item).id,
          where: j.worker == ^worker_name and j.state in ^@active_job_states,
          select: 1
        )
      )
    )
  end

  defp do_delete_media_files(media_item) do
    mapped_struct = Map.from_struct(media_item)

    MediaItem.filepath_attributes()
    |> Enum.map(fn
      :subtitle_filepaths = field -> Enum.map(mapped_struct[field], fn [_, filepath] -> filepath end)
      field -> List.wrap(mapped_struct[field])
    end)
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)

    {:ok, media_item}
  end

  defp delete_internal_metadata_files(media_item) do
    metadata = Repo.preload(media_item, :metadata).metadata || %MediaMetadata{}
    mapped_struct = Map.from_struct(metadata)

    MediaMetadata.filepath_attributes()
    |> Enum.map(fn field -> mapped_struct[field] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)
  end

  defp run_user_script(event, media_item) do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)

    runner.run(event, media_item)
  end
end
