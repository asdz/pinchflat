defmodule Pinchflat.Media.MediaQueryPlanTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Media.MediaQuery

  # `media_items` rows are large (they hold each video's description) and these queries run
  # constantly: after every index of every source, and on every visit to the home page.
  # On a big library they're only fast if SQLite can answer them from an index rather than
  # reading every row, so check that it actually does. If one of these fails, a query or an
  # index changed in a way that brings the full scans back.
  describe "query plans" do
    test "finding a source's pending media only looks at media that isn't downloaded" do
      source = source_fixture()

      plan =
        MediaItem
        |> MediaQuery.require_assoc(:media_profile)
        |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending()))
        |> query_plan()

      assert plan =~ "source_id=? AND media_filepath=?"
    end

    test "the home page's pending list only looks at media that isn't downloaded" do
      plan =
        MediaItem
        |> MediaQuery.require_assoc(:media_profile)
        |> where(^MediaQuery.pending())
        |> order_by(desc: :id)
        |> limit(5)
        |> query_plan()

      assert plan =~ "media_items_not_downloaded_index"
    end

    test "the home page's download totals are read from an index" do
      downloaded = where(MediaItem, ^MediaQuery.downloaded())

      assert query_plan(select(downloaded, [mi], sum(mi.media_size_bytes))) =~ "USING COVERING INDEX"
      assert query_plan(select(downloaded, [mi], count(mi.id))) =~ "USING COVERING INDEX"
    end

    test "counting a source's downloaded media is read from an index" do
      source = source_fixture()

      plan =
        MediaItem
        |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded()))
        |> select([mi], count(mi.id))
        |> query_plan()

      assert plan =~ "USING COVERING INDEX"
    end
  end

  defp query_plan(query) do
    {sql, params} = Repo.to_sql(:all, query)
    %{rows: rows} = Repo.query!("EXPLAIN QUERY PLAN " <> sql, params)

    Enum.map_join(rows, "\n", &List.last/1)
  end
end
