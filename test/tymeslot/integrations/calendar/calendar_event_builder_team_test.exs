defmodule Tymeslot.Integrations.Calendar.CalendarEventBuilderTeamTest do
  @moduledoc """
  A team meeting is written once, to the calendar its team meeting type names,
  with every member listed as an attendee so that it reaches their own
  calendars too.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :teams
  @moduletag :calendar

  import Tymeslot.TeamTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder
  alias Tymeslot.Meetings.CoHostQueries

  test "a team meeting lists the booker and every co-host as attendees" do
    %{team: team, members: [owner, second, third]} = create_team_with_members(3)

    meeting =
      insert(:meeting,
        organizer_user_id: owner.user.id,
        team_id: team.id,
        attendee_email: "booker@example.com",
        attendee_name: "Booker"
      )

    {:ok, 2} = CoHostQueries.insert_all_for_meeting(meeting.id, [second.user.id, third.user.id])

    assert %{attendees: [booker | co_hosts]} = CalendarEventBuilder.build_event_data(meeting)
    assert %{email: "booker@example.com", response_status: nil} = booker

    assert co_hosts |> Enum.map(& &1.email) |> Enum.sort() ==
             Enum.sort([second.user.email, third.user.email])

    assert Enum.all?(co_hosts, &(&1.response_status == :accepted))
  end

  test "a personal meeting keeps its single attendee" do
    meeting = insert(:meeting, attendee_email: "booker@example.com")

    refute Map.has_key?(CalendarEventBuilder.build_event_data(meeting), :attendees)
  end
end
