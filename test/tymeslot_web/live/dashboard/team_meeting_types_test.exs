defmodule TymeslotWeb.Dashboard.TeamMeetingTypesTest do
  @moduledoc """
  Team meeting types in the dashboard: created once in the meeting settings,
  with the same form as the user's own types, then offered per team from the
  Teams page.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :teams
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Teams

  setup :setup_dashboard_user

  test "lists the user's team meeting types and the teams offering them",
       %{conn: conn, user: user} do
    {:ok, team} = Teams.create_team(user.id, %{name: "Sales"})
    type = insert(:meeting_type, user: user, is_team_type: true, name: "Sales intro")
    {:ok, _team} = Teams.offer_meeting_type(team.id, user.id, type.id)

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    assert has_element?(view, "#team-meeting-types", "Sales intro")
    assert has_element?(view, "#team-meeting-types", "Offered by: Sales")
  end

  test "is hidden for a user who owns no team", %{conn: conn, user: user} do
    owner = insert(:user)
    {:ok, team} = Teams.create_team(owner.id, %{name: "Someone else's"})
    {:ok, _team} = Teams.add_member_by_email(team.id, owner.id, user.email)

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    refute has_element?(view, "#team-meeting-types")
  end

  test "creates a team meeting type, offering neither payment nor a schedule",
       %{conn: conn, user: user} do
    {:ok, _team} = Teams.create_team(user.id, %{name: "Sales"})
    # The same name as one of the user's own types: team types are named apart.
    insert(:meeting_type, user: user, name: "Quick Coffee")

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view |> element("#team-meeting-types button", "Add a team meeting type") |> render_click()

    html = render(view)
    assert html =~ "Add a team meeting type"
    assert html =~ "each member&#39;s own default schedule applies"

    # See MeetingSettingsTest: the default reminder's hidden inputs cannot be
    # re-encoded by LiveViewTest, so it is removed before submitting.
    view |> element("button[aria-label='Remove reminder']") |> render_click()

    view
    |> form("form[phx-submit='save_meeting_type']", %{
      "meeting_type" => %{"name" => "Quick Coffee", "duration" => "20"}
    })
    |> render_submit()

    assert [%{name: "Quick Coffee", duration_minutes: 20, teams: []}] =
             MeetingTypes.list_user_team_meeting_types(user.id)

    # Still one personal "Quick Coffee", untouched.
    assert [_personal] =
             user.id
             |> MeetingTypes.get_all_meeting_types()
             |> Enum.filter(&(&1.name == "Quick Coffee"))
  end

  test "the Teams page orders the team's meeting types by dragging",
       %{conn: conn, user: user} do
    {:ok, team} = Teams.create_team(user.id, %{name: "Sales"})
    a = insert(:meeting_type, user: user, is_team_type: true, name: "Intro")
    b = insert(:meeting_type, user: user, is_team_type: true, name: "Demo")
    {:ok, _team} = Teams.offer_meeting_type(team.id, user.id, a.id)
    {:ok, _team} = Teams.offer_meeting_type(team.id, user.id, b.id)

    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")
    view |> element("#team-card-#{team.id} button", "Manage") |> render_click()

    view
    |> element("#team-offered-sortable-list")
    |> render_hook("reorder_meeting_types", %{"ids" => [b.id, a.id]})

    assert Enum.map(Teams.get_team_for_booking(team.id).meeting_types, & &1.id) == [b.id, a.id]
  end

  test "the Teams page offers a team meeting type on a team", %{conn: conn, user: user} do
    {:ok, team} = Teams.create_team(user.id, %{name: "Sales"})
    type = insert(:meeting_type, user: user, is_team_type: true, name: "Sales intro")

    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")
    view |> element("#team-card-#{team.id} button", "Manage") |> render_click()

    view
    |> element("#team-offered-types #team-type-toggle-#{type.id}")
    |> render_click()

    assert [%{id: id}] = Teams.get_team_for_booking(team.id).meeting_types
    assert id == type.id
    assert has_element?(view, "#offer-type-#{type.id}", "Sales intro")

    # Switched off again, the team stops offering it.
    view
    |> element("#team-offered-types #team-type-toggle-#{type.id}")
    |> render_click()

    assert Teams.get_team_for_booking(team.id).meeting_types == []
  end
end
