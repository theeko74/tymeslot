defmodule Tymeslot.Availability.TeamOfferTest do
  @moduledoc """
  What a team page offers: only the times every member is free, each member
  weighed against their own schedule and bookings.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :teams
  @moduletag :availability

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.TeamTestHelpers

  alias Tymeslot.Availability.{Offer, TeamOffer}
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.{CoHostQueries, MeetingSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Teams
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()
    :ok
  end

  defp requests(team) do
    team
    |> Teams.member_profiles()
    |> TeamOffer.requests(%{
      profile: nil,
      user_timezone: "Etc/UTC",
      meeting_type: team.meeting_type
    })
  end

  defp team_slots(team, date) do
    AvailabilityCache.clear_all()
    {:ok, slots} = TeamOffer.slots_for_date(requests(team), Date.to_iso8601(date), 60)
    slots
  end

  defp book(user_id, date, time) do
    start_time = DateTime.new!(date, time, "Etc/UTC")

    insert(:meeting,
      organizer_user_id: user_id,
      status: "confirmed",
      start_time: start_time,
      end_time: DateTime.add(start_time, 60, :minute)
    )
  end

  test "offers only the hours every member's schedule has in common" do
    %{team: team} =
      create_team_with_members(2,
        members: [
          [
            timezone: "Etc/UTC",
            hours: %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[15:00:00]}
          ],
          [
            timezone: "Etc/UTC",
            hours: %{is_available: true, start_time: ~T[12:00:00], end_time: ~T[18:00:00]}
          ]
        ]
      )

    slots = team_slots(team, next_bookable_weekday())

    assert slots == ["12:00 PM", "1:00 PM", "2:00 PM"]
  end

  test "a member's booking removes the time from the team page" do
    %{team: team, members: [_owner, member]} = create_team_with_members(2)
    date = next_bookable_weekday()

    assert "2:00 PM" in team_slots(team, date)

    book(member.user.id, date, ~T[14:00:00])

    refute "2:00 PM" in team_slots(team, date)
  end

  test "a team booking blocks a co-host on their own page" do
    %{team: team, members: [owner, member]} = create_team_with_members(2)
    date = next_bookable_weekday()

    meeting = book(owner.user.id, date, ~T[14:00:00])
    CoHostQueries.insert_all_for_meeting(meeting.id, [member.user.id])
    Repo.update_all(MeetingSchema, set: [team_id: team.id])

    AvailabilityCache.clear_all()

    {:ok, own_slots} =
      Offer.slots_for_date(
        %{profile: member.profile, user_timezone: "Etc/UTC", meeting_type: nil},
        Date.to_iso8601(date),
        60
      )

    refute "2:00 PM" in own_slots
  end

  test "a day closed for any member is closed for the team" do
    %{team: team} =
      create_team_with_members(2,
        members: [[timezone: "Etc/UTC"], [timezone: "Etc/UTC", days: [2, 3, 4, 5]]]
      )

    monday = Date.add(Date.beginning_of_week(Date.add(Date.utc_today(), 14)), 0)
    tuesday = Date.add(monday, 1)

    AvailabilityCache.clear_all()
    {:ok, days} = TeamOffer.days_in_range(requests(team), monday, tuesday, 60)

    assert days[Date.to_iso8601(monday)] == false
    assert days[Date.to_iso8601(tuesday)] == true
  end

  test "an unreadable member calendar fails the whole answer" do
    %{team: team} = create_team_with_members(2)

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
      {:error, :all_calendars_unavailable}
    end)

    assert {:error, _reason} =
             TeamOffer.slots_for_date(
               requests(team),
               Date.to_iso8601(next_bookable_weekday()),
               60
             )
  end
end
