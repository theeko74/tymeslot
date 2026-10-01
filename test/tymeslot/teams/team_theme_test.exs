defmodule Tymeslot.Teams.TeamThemeTest do
  @moduledoc """
  A team page's style: its own theme and customisation, falling back to its
  owner's.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :teams

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Teams
  alias Tymeslot.ThemeCustomizations
  alias TymeslotWeb.Themes.Shared.Customization.Helpers, as: CustomizationHelpers

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, booking_theme: "1")
    {:ok, team} = Teams.create_team(user.id, %{name: "Sales"})
    %{user: user, profile: profile, team: team}
  end

  describe "booking_theme/1" do
    test "is the owner's until the team has its own", %{user: user, team: team} do
      assert Teams.booking_theme(team) == "1"
      assert Teams.page_theme_by_slug(team.slug) == "1"

      {:ok, team} = Teams.update_booking_theme(team.id, user.id, "2")

      assert Teams.booking_theme(team) == "2"
      assert Teams.page_theme_by_slug(team.slug) == "2"
    end

    test "is nil for an unknown team" do
      assert Teams.page_theme_by_slug("no-such-team") == nil
    end
  end

  describe "update_booking_theme/3" do
    test "is the owner's alone", %{team: team} do
      member = insert(:user)

      assert {:error, :not_found} = Teams.update_booking_theme(team.id, member.id, "2")
    end

    test "refuses an unknown theme", %{user: user, team: team} do
      assert {:error, %Ecto.Changeset{}} = Teams.update_booking_theme(team.id, user.id, "999")
    end

    test "nil makes the page wear its owner's again", %{user: user, team: team} do
      {:ok, _team} = Teams.update_booking_theme(team.id, user.id, "2")
      {:ok, team} = Teams.update_booking_theme(team.id, user.id, nil)

      assert team.booking_theme == nil
      assert Teams.booking_theme(team) == "1"
    end
  end

  describe "the public page's customisation" do
    test "is the team's own when it has one", %{profile: profile, team: team} do
      {:ok, _owner_row} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "ocean"
        })

      {:ok, _team_row} =
        ThemeCustomizations.upsert_theme_customization(
          Teams.customization_owner(team),
          "1",
          %{"color_scheme" => "forest"}
        )

      assert %{theme_customization: %{color_scheme: "forest", team_id: team_id}} =
               assign_for(team, profile)

      assert team_id == team.id

      # The owner's own page is unchanged.
      assert %{theme_customization: %{color_scheme: "ocean", team_id: nil}} =
               assign_for(nil, profile)
    end

    test "falls back to the owner's", %{profile: profile, team: team} do
      {:ok, _owner_row} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "ocean"
        })

      assert %{has_custom_theme: true, theme_customization: %{color_scheme: "ocean"}} =
               assign_for(team, profile)
    end
  end

  defp assign_for(team, profile) do
    socket = %Socket{assigns: %{__changed__: %{}, team: team}}
    CustomizationHelpers.assign_theme_customization(socket, profile, "1").assigns
  end
end
