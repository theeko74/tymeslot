defmodule Tymeslot.Bookings.CreateTeamBookingTest do
  @moduledoc """
  A booking made on a team page: one meeting organised by the team's owner,
  every other member a co-host, and each of them checked against their own
  schedule, bookings and limits before it is taken.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :teams
  @moduletag :bookings

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.TeamTestHelpers

  alias Tymeslot.Bookings.{Create, Policy}
  alias Tymeslot.Meetings.CoHostQueries
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    :ok
  end

  @opts [skip_calendar_check: true]

  defp params(team, date, time \\ "2:00 PM") do
    %{
      date: date,
      time: time,
      duration: 60,
      user_timezone: "Etc/UTC",
      organizer_user_id: team.owner_user_id,
      meeting_type_id: team.meeting_type.id,
      team_id: team.id
    }
  end

  defp form_data, do: %{"name" => "Booker", "email" => "booker@example.com", "message" => ""}

  defp book(user_id, date, time) do
    start_time = DateTime.new!(date, time, "Etc/UTC")

    insert(:meeting,
      organizer_user_id: user_id,
      status: "confirmed",
      start_time: start_time,
      end_time: DateTime.add(start_time, 60, :minute)
    )
  end

  test "books one meeting for the owner with every other member as co-host" do
    %{team: team, members: [owner, second, third]} = create_team_with_members(3)

    assert {:ok, meeting} =
             Create.execute(params(team, next_bookable_weekday()), form_data(), @opts)

    assert meeting.organizer_user_id == owner.user.id
    assert meeting.team_id == team.id
    assert meeting.reschedule_url == nil

    assert Enum.sort(CoHostQueries.user_ids_for_meeting(meeting.id)) ==
             Enum.sort([second.user.id, third.user.id])

    assert {:error, _cannot} = Policy.can_reschedule_meeting?(meeting)
  end

  test "refuses a time a co-host's schedule does not offer" do
    %{team: team} =
      create_team_with_members(2,
        members: [
          [timezone: "Etc/UTC"],
          [
            timezone: "Etc/UTC",
            hours: %{is_available: true, start_time: ~T[15:00:00], end_time: ~T[17:00:00]}
          ]
        ]
      )

    assert {:error, _not_offered} =
             Create.execute(params(team, next_bookable_weekday()), form_data(), @opts)
  end

  test "refuses a time a co-host is already booked for" do
    %{team: team, members: [_owner, member]} = create_team_with_members(2)
    date = next_bookable_weekday()
    book(member.user.id, date, ~T[14:00:00])

    assert {:error, :slot_taken} = Create.execute(params(team, date), form_data(), @opts)
  end

  test "a team meeting blocks its co-hosts for the next team booking" do
    %{team: team} = create_team_with_members(2)
    date = next_bookable_weekday()

    assert {:ok, _meeting} = Create.execute(params(team, date), form_data(), @opts)
    assert {:error, :slot_taken} = Create.execute(params(team, date), form_data(), @opts)
  end

  test "refuses a team paired with another meeting type, or its type booked without it" do
    %{team: team, members: [owner, _member]} = create_team_with_members(2)
    personal = insert(:meeting_type, user: owner.user)
    date = next_bookable_weekday()

    assert {:error, :meeting_type_not_found} =
             Create.execute(
               %{params(team, date) | meeting_type_id: personal.id},
               form_data(),
               @opts
             )

    assert {:error, :meeting_type_not_found} =
             Create.execute(%{params(team, date) | team_id: nil}, form_data(), @opts)
  end
end
