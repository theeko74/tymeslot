defmodule Tymeslot.Notifications.TeamNotifications do
  @moduledoc """
  Tells the co-hosts of a team meeting what the organiser is told.

  A meeting booked on a team page is organised by the team's owner, who
  receives the usual organiser emails. Every other member is a co-host
  (`Tymeslot.Meetings.CoHostSchema`) and receives the same organiser email for
  the confirmation and the cancellation, addressed to them: in their own
  language, timezone and time format, as if they were the organiser.

  Co-host emails never fail the job that triggered them: a failed send is
  logged, and the organiser's and booker's emails are unaffected.
  """

  require Logger

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.CoHostQueries
  alias Tymeslot.Profiles

  @doc """
  Sends the organiser's confirmation to every co-host not yet sent it, and
  stamps each one sent.
  """
  @spec notify_confirmed(map()) :: :ok
  def notify_confirmed(%{team_id: team_id} = meeting) when is_integer(team_id) do
    meeting.id
    |> CoHostQueries.list_for_meeting()
    |> Enum.filter(&is_nil(&1.confirmation_sent_at))
    |> Enum.each(fn co_host ->
      details = details_for(meeting, co_host)

      case Config.email_service_module().send_appointment_confirmation_to_organizer(
             details.organizer_email,
             details
           ) do
        {:ok, _result} ->
          CoHostQueries.mark_confirmation_sent(co_host, DateTime.utc_now(:second))

        error ->
          log_failure("confirmation", meeting, co_host, error)
      end
    end)
  end

  def notify_confirmed(_meeting), do: :ok

  @doc """
  Sends the organiser's cancellation to every co-host. `once` guards each send
  against a rescued job repeating it (`Tymeslot.Workers.DeliveryClaims`).
  """
  @spec notify_cancelled(map(), (String.t(), (-> term()) -> term())) :: :ok
  def notify_cancelled(meeting, once \\ fn _key, send -> send.() end)

  def notify_cancelled(%{team_id: team_id} = meeting, once) when is_integer(team_id) do
    meeting.id
    |> CoHostQueries.list_for_meeting()
    |> Enum.each(fn co_host ->
      once.("cancellation:co_host:#{co_host.user_id}", fn ->
        details = details_for(meeting, co_host)

        case Config.email_service_module().send_appointment_cancellation(
               details.organizer_email,
               details
             ) do
          {:ok, _result} = ok ->
            ok

          error ->
            log_failure("cancellation", meeting, co_host, error)
            :ok
        end
      end)
    end)
  end

  def notify_cancelled(_meeting, _once), do: :ok

  # The organiser's payload, rebuilt with the co-host standing in as the
  # organiser, so that everything read off the organiser (language, timezone,
  # time format, avatar) is theirs.
  defp details_for(meeting, %{user: user}) do
    name = Profiles.display_name(user.profile) || user.name || user.email

    meeting
    |> Map.merge(%{organizer_user_id: user.id, organizer_email: user.email, organizer_name: name})
    |> AppointmentBuilder.from_meeting()
  end

  defp log_failure(kind, meeting, co_host, error) do
    Logger.warning("Co-host email failed",
      email_kind: kind,
      meeting_id: meeting.id,
      co_host_user_id: co_host.user_id,
      error: LogFormat.reason(error)
    )
  end
end
