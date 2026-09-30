defmodule TymeslotWeb.Dashboard.TeamsTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :teams
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Teams

  defp setup_user(_context) do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user)
    {:ok, conn: log_in(build_conn(), user), user: user}
  end

  defp log_in(conn, user) do
    conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
  end

  setup :setup_user

  test "shows an empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/dashboard/teams")
    assert html =~ "You are not in any team yet"
  end

  test "creates a team with a slug derived from its name", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")

    view |> element("button", "New team") |> render_click()

    view
    |> form("#team-edit-form", %{
      "team" => %{
        "name" => "Growth Team",
        "slug" => "",
        "description" => "",
        "duration_minutes" => "45"
      }
    })
    |> render_submit()

    assert [%{name: "Growth Team", slug: "growth-team", duration_minutes: 45}] =
             Teams.list_teams_for_user(user.id)

    assert render(view) =~ "/team/growth-team"
  end

  test "adds a member by email and reports an unknown address", %{conn: conn, user: user} do
    {:ok, team} = Teams.create_team(user.id, %{name: "Support", duration_minutes: 30})
    colleague = insert(:user, email: "colleague@example.com")
    insert(:profile, user: colleague)

    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")
    view |> element("#team-card-#{team.id} button", "Manage") |> render_click()

    view |> form("#add-member-form", %{"email" => "nobody@example.com"}) |> render_submit()
    assert render(view) =~ "No Tymeslot account uses this email address."

    view |> form("#add-member-form", %{"email" => "colleague@example.com"}) |> render_submit()
    assert render(view) =~ "colleague@example.com"

    assert {:ok, %{members: members}} = Teams.get_team_for_owner(team.id, user.id)
    assert length(members) == 2
  end

  test "a member sees the team and can leave it", %{conn: conn, user: user} do
    owner = insert(:user)
    insert(:profile, user: owner)
    {:ok, team} = Teams.create_team(owner.id, %{name: "Owned Elsewhere", duration_minutes: 30})
    {:ok, _team} = Teams.add_member_by_email(team.id, owner.id, user.email)

    {:ok, view, html} = live(conn, ~p"/dashboard/teams")
    assert html =~ "Owned Elsewhere"

    view |> element("#team-card-#{team.id} button", "Manage") |> render_click()
    refute has_element?(view, "#add-member-form")

    view |> element("button", "Leave team") |> render_click()

    assert Teams.list_teams_for_user(user.id) == []
  end

  test "does not list other users' teams", %{conn: conn} do
    other = insert(:user)
    {:ok, _team} = Teams.create_team(other.id, %{name: "Private Crew", duration_minutes: 30})

    {:ok, _view, html} = live(conn, ~p"/dashboard/teams")
    refute html =~ "Private Crew"
  end

  test "the owner deletes a team after confirming", %{conn: conn, user: user} do
    {:ok, team} = Teams.create_team(user.id, %{name: "Short Lived", duration_minutes: 30})

    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")
    view |> element("#team-card-#{team.id} button", "Manage") |> render_click()
    view |> element("#team-detail button", "Delete") |> render_click()
    view |> element("#delete-team-modal button", "Delete team") |> render_click()

    assert Teams.list_teams_for_user(user.id) == []
  end
end
