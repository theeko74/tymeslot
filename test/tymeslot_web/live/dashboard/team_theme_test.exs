defmodule TymeslotWeb.Dashboard.TeamThemeTest do
  @moduledoc """
  The style of a team page, chosen and customised from the Theme tab by the
  team's owner, apart from the owner's own page.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :teams
  @moduletag :live

  import Ecto.Query
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Repo
  alias Tymeslot.Teams
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  setup :setup_dashboard_user_with_theme

  test "lists the teams the user owns, not those they only belong to",
       %{conn: conn, user: user} do
    {:ok, _owned} = Teams.create_team(user.id, %{name: "Sales"})

    owner = insert(:user)
    {:ok, other} = Teams.create_team(owner.id, %{name: "Someone else's"})
    {:ok, _other} = Teams.add_member_by_email(other.id, owner.id, user.email)

    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    assert has_element?(view, "#team-themes", "Sales")
    refute has_element?(view, "#team-themes", "Someone else's")
  end

  test "is hidden for a user who owns no team", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    refute has_element?(view, "#team-themes")
  end

  test "chooses the team page's style without touching the owner's",
       %{conn: conn, user: user, profile: profile} do
    {:ok, team} = Teams.create_team(user.id, %{name: "Sales"})

    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    view |> element("#select-team-theme-#{team.id}-2") |> render_click()

    assert Repo.reload!(team).booking_theme == "2"
    assert Repo.reload!(profile).booking_theme == "1"

    # Back to the owner's style.
    view |> element("#reset-team-theme-#{team.id}") |> render_click()

    assert Repo.reload!(team).booking_theme == nil
  end

  test "customises the team page apart from the owner's page",
       %{conn: conn, user: user, profile: profile} do
    {:ok, team} = Teams.create_team(user.id, %{name: "Sales"})

    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    view |> element("#customize-team-theme-#{team.id}-1") |> render_click()

    assert_patch(view, ~p"/dashboard/theme/team/#{team.id}/customize/1")
    assert has_element?(view, "#team-theme-customization-target", "Sales")
    # A signed owner preview, so a test booking there is only simulated.
    assert has_element?(
             view,
             "a[href^='/team/#{team.slug}?'][href*='theme=1'][href*='preview_token=']"
           )

    view
    |> element("button[phx-click='theme:select_color_scheme'][phx-value-scheme='forest']")
    |> render_click()

    assert %{color_scheme: "forest", profile_id: profile_id} =
             Repo.get_by(ThemeCustomizationSchema, team_id: team.id, theme_id: "1")

    assert profile_id == profile.id

    # The owner's own customisation is a separate row, never written.
    assert Repo.all(
             from(c in ThemeCustomizationSchema,
               where: c.profile_id == ^profile.id and is_nil(c.team_id)
             )
           ) == []
  end

  test "sets the team page's wording apart from the owner's",
       %{conn: conn, user: user, profile: profile} do
    {:ok, team} = Teams.create_team(user.id, %{name: "Sales"})

    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    # Switched on, the wording is seeded from the lines it replaces.
    view |> element("#team-booking-text-#{team.id}-enabled") |> render_click()

    assert %{booking_text_enabled: true, booking_heading: "Sales"} = Repo.reload!(team)

    view
    |> form("#team-booking-text-#{team.id}-form", %{
      "team_schema" => %{
        "booking_text_enabled" => "true",
        "booking_heading" => "Talk to Sales",
        "booking_greeting" => "We answer within a day",
        "booking_instruction" => "Pick a format"
      }
    })
    |> render_change()

    assert %{
             booking_heading: "Talk to Sales",
             booking_greeting: "We answer within a day",
             booking_instruction: "Pick a format"
           } = Repo.reload!(team)

    assert has_element?(view, "#team-booking-text-#{team.id} iframe[src^='/team/#{team.slug}?']")
    assert Repo.reload!(profile).booking_text_enabled == false
  end

  # The smallest valid PNG: a one-pixel image.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
       )

  test "uploads and removes the team's logo", %{conn: conn, user: user} do
    {:ok, team} = Teams.create_team(user.id, %{name: "Sales"})

    on_exit(fn ->
      dir = Application.fetch_env!(:tymeslot, :upload_directory)
      File.rm_rf(Path.join([dir, "team_logos", to_string(team.id)]))
    end)

    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    view
    |> file_input("#team-logo-#{team.id}-form", :team_logo, [
      %{name: "logo.png", content: @png, type: "image/png"}
    ])
    |> render_upload("logo.png")

    assert %{logo: logo} = Repo.reload!(team)
    assert logo =~ ~r/^#{team.id}_logo_\d+_\d+\.png$/

    assert has_element?(
             view,
             "#team-logo-#{team.id} img[src='/uploads/team_logos/#{team.id}/#{logo}']"
           )

    view |> element("#team-logo-#{team.id}-remove") |> render_click()

    assert Repo.reload!(team).logo == nil
  end

  test "does not open the customisation of a team the user does not own",
       %{conn: conn, user: user} do
    owner = insert(:user)
    insert(:profile, user: owner)
    {:ok, other} = Teams.create_team(owner.id, %{name: "Someone else's"})
    {:ok, _other} = Teams.add_member_by_email(other.id, owner.id, user.email)

    {:ok, view, _html} = live(conn, ~p"/dashboard/theme/team/#{other.id}/customize/1")

    refute has_element?(view, "#team-theme-customization-target")
    assert render(view) =~ "Choose Your Style"
  end
end
