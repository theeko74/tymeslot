defmodule Tymeslot.Notifications.TeamNotificationsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :teams
  @moduletag :notifications

  import Mox
  import Tymeslot.TeamTestHelpers

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.CoHostQueries
  alias Tymeslot.Notifications.TeamNotifications
  alias Tymeslot.Workers.EmailWorkerHandlers.TeamEmails

  setup :verify_on_exit!

  setup do
    %{team: team, members: [owner, member]} = create_team_with_members(2)
    start_time = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

    meeting =
      insert(:meeting,
        organizer_user_id: owner.user.id,
        organizer_email: owner.user.email,
        team_id: team.id,
        status: "confirmed",
        start_time: start_time,
        end_time: DateTime.add(start_time, 60, :minute)
      )

    {:ok, _count} = CoHostQueries.insert_all_for_meeting(meeting.id, [member.user.id])

    %{team: team, meeting: meeting, member: member}
  end

  test "each co-host is sent the organiser's confirmation, addressed to them, once", %{
    meeting: meeting,
    member: member
  } do
    member_email = member.user.email

    expect(EmailServiceMock, :send_appointment_confirmation_to_organizer, 1, fn ^member_email,
                                                                                details ->
      assert details.organizer_email == member_email
      {:ok, :sent}
    end)

    assert :ok = TeamNotifications.notify_confirmed(meeting)
    # Stamped, so a retry does not send it again.
    assert :ok = TeamNotifications.notify_confirmed(meeting)
  end

  test "each co-host is told of the cancellation", %{meeting: meeting, member: member} do
    member_email = member.user.email

    expect(EmailServiceMock, :send_appointment_cancellation, 1, fn ^member_email, _details ->
      {:ok, :sent}
    end)

    assert :ok = TeamNotifications.notify_cancelled(meeting)
  end

  test "a personal meeting has no co-hosts to tell", %{meeting: meeting} do
    assert :ok = TeamNotifications.notify_confirmed(%{meeting | team_id: nil})
  end

  test "the member-added email renders and is delivered", %{team: team, member: member} do
    assert :ok =
             TeamEmails.handle_member_added(%{"team_id" => team.id, "user_id" => member.user.id})
  end

  test "the member-added email is discarded once the membership is gone", %{team: team} do
    assert {:discard, _reason} =
             TeamEmails.handle_member_added(%{"team_id" => team.id, "user_id" => -1})
  end
end
