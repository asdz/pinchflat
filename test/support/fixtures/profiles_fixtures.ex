defmodule Pinchflat.ProfilesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Pinchflat.Profiles` context.
  """

  @doc """
  Generate a media_profile.
  """
  def media_profile_fixture(attrs \\ %{}) do
    {:ok, media_profile} =
      attrs
      |> Enum.into(%{
        # Names must be unique. A random number isn't: now and then two profiles in one test
        # drew the same one and the whole suite failed.
        name: "Media Profile ##{System.unique_integer([:positive])}",
        output_path_template: "{{title}}.{{ext}}"
      })
      |> Pinchflat.Profiles.create_media_profile()

    media_profile
  end
end
