defmodule Tymeslot.Meetings.Scheduling do
  @moduledoc """
  Business logic for meeting scheduling, conflict detection, and time management.

  This module handles:
  - Conflict detection with buffered time windows
  - Atomic meeting creation/updates with conflict checking
  - Buffer time calculations based on organizer settings
  """

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Meetings.BookingLimits
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Utils.MapKeys

  @doc """
  Atomically creates a meeting with conflict checking using database-level locking.
  This function ensures no race conditions can occur by using a database transaction
  with row-level locking to prevent concurrent bookings of overlapping time slots.

  The host's booking limits are enforced in the same transaction. Pass
  `enforce_booking_limits: false` (host-created ad-hoc bookings) to skip
  them; conflict checking always runs.

  Pass `co_host_user_ids: [id, ...]` for a team booking: every co-host's
  conflicts and booking limits are then checked in the same transaction as the
  organiser's, so none of them can be double-booked by a concurrent submit.

  ## Examples

      iex> create_meeting_with_conflict_check(%{uid: "unique-123", title: "Meeting", start_time: ~U[2024-01-01 10:00:00Z], end_time: ~U[2024-01-01 11:00:00Z]})
      {:ok, %Meeting{}}

      iex> create_meeting_with_conflict_check(%{uid: "conflicting-123", title: "Meeting", start_time: ~U[2024-01-01 10:00:00Z], end_time: ~U[2024-01-01 11:00:00Z]})
      {:error, :time_conflict}

  """
  @spec create_meeting_with_conflict_check(map(), keyword()) ::
          {:ok, Meeting.t()}
          | {:error,
             :time_conflict
             | :booking_limit_reached
             | :invalid_time_range
             | :database_error
             | {:validation_error, Changeset.t()}}
  def create_meeting_with_conflict_check(attrs, opts \\ []) do
    start_time = MapKeys.get(attrs, :start_time)
    end_time = MapKeys.get(attrs, :end_time)
    organizer_user_id = MapKeys.get(attrs, :organizer_user_id)
    meeting_type_id = MapKeys.get(attrs, :meeting_type_id)

    if start_time && end_time do
      hosts =
        host_checks(
          organizer_user_id,
          meeting_type_id,
          Keyword.get(opts, :co_host_user_ids, []),
          start_time,
          end_time,
          opts
        )

      execute_conflict_checked_transaction(start_time, end_time, hosts, fn ->
        create_meeting_in_transaction(attrs)
      end)
    else
      {:error, :invalid_time_range}
    end
  rescue
    error ->
      handle_database_error(error, __STACKTRACE__, %{
        operation: "create",
        organizer_user_id: MapKeys.get(attrs, :organizer_user_id)
      })
  end

  @doc """
  Atomically updates a meeting with conflict checking using database-level locking.
  This function ensures no race conditions can occur when rescheduling meetings
  by checking for conflicts with other meetings atomically.

  ## Examples

      iex> update_meeting_with_conflict_check(meeting, %{start_time: ~U[2024-01-01 10:00:00Z], end_time: ~U[2024-01-01 11:00:00Z]})
      {:ok, %Meeting{}}

      iex> update_meeting_with_conflict_check(meeting, %{start_time: ~U[2024-01-01 10:00:00Z], end_time: ~U[2024-01-01 11:00:00Z]})
      {:error, :time_conflict}

  """
  @spec update_meeting_with_conflict_check(Meeting.t(), map(), keyword()) ::
          {:ok, Meeting.t()}
          | {:error,
             :time_conflict
             | :booking_limit_reached
             | :database_error
             | Changeset.t()
             | {:validation_error, Changeset.t()}}
  def update_meeting_with_conflict_check(%Meeting{} = meeting, attrs, opts \\ []) do
    # Only check conflicts if time is being changed
    start_time = MapKeys.get(attrs, :start_time)
    end_time = MapKeys.get(attrs, :end_time)

    if start_time && end_time do
      execute_update_with_conflict_check(meeting, attrs, start_time, end_time, opts)
    else
      # No time change, just do regular update without conflict checking
      MeetingQueries.update_meeting(meeting, attrs)
    end
  rescue
    error ->
      handle_database_error(error, __STACKTRACE__, %{operation: "update", meeting_id: meeting.id})
  end

  # Private functions

  # One entry per host the new meeting occupies: the organiser, and on a team
  # booking every co-host (`opts[:co_host_user_ids]`). Each is checked against
  # their own rules: the organiser against the booked meeting type, a co-host
  # against their default schedule's buffer and their profile's booking caps,
  # which is what the team page offered them on (`TeamOffer`).
  #
  # Sorted by user id so that two team bookings sharing members take the
  # advisory limit locks and the conflict row locks in the same order.
  defp host_checks(
         organizer_user_id,
         meeting_type_id,
         co_host_user_ids,
         start_time,
         end_time,
         opts
       ) do
    co_hosts = co_host_user_ids |> Enum.reject(&(&1 == organizer_user_id)) |> Enum.uniq()

    [{organizer_user_id, meeting_type_id} | Enum.map(co_hosts, &{&1, nil})]
    |> Enum.sort_by(fn {user_id, _type_id} -> user_id || 0 end)
    |> Enum.map(fn {user_id, type_id} ->
      %{
        user_id: user_id,
        limit_check: build_limit_check(user_id, start_time, type_id, nil, opts),
        window: compute_buffered_window(start_time, end_time, user_id, type_id)
      }
    end)
  end

  defp execute_conflict_checked_transaction(start_time, end_time, hosts, operation_fn) do
    Repo.transaction(fn ->
      case check_hosts(hosts) do
        :ok ->
          operation_fn.()

        {:error, :booking_limit_reached} ->
          Repo.rollback(:booking_limit_reached)

        {:error, conflicting_count} ->
          log_conflict(start_time, end_time, conflicting_count)
          Repo.rollback(:time_conflict)
      end
    end)
  end

  defp check_hosts(hosts) do
    Enum.reduce_while(hosts, :ok, fn %{window: {buffered_start, buffered_end}} = host, :ok ->
      with :ok <- enforce_booking_limits(host.limit_check),
           {:ok, :no_conflicts} <-
             MeetingConflictQueries.count_locked_conflicts(
               buffered_start,
               buffered_end,
               nil,
               host.user_id
             ) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  # nil means limits are not applicable to this call (disabled via opts, or
  # no organizer to protect).
  defp build_limit_check(organizer_user_id, start_time, meeting_type_id, exclude_uid, opts) do
    if Keyword.get(opts, :enforce_booking_limits, true) and is_integer(organizer_user_id) do
      %{
        organizer_user_id: organizer_user_id,
        start_time: start_time,
        meeting_type_id: meeting_type_id,
        exclude_uid: exclude_uid
      }
    end
  end

  defp enforce_booking_limits(nil), do: :ok

  defp enforce_booking_limits(%{organizer_user_id: organizer_user_id} = limit_check) do
    settings = Profiles.get_profile_settings(organizer_user_id)
    meeting_type = fetch_meeting_type(limit_check.meeting_type_id, organizer_user_id)
    limits = BookingLimits.limits_for(settings, meeting_type)

    if BookingLimits.enabled?(limits) do
      # Row locks cannot serialise limit counts — concurrent bookings occupy
      # different, non-overlapping windows — so serialise per host instead.
      # Hosts without limits never reach this and keep full concurrency.
      MeetingConflictQueries.acquire_booking_limits_lock(organizer_user_id)

      Checker.check_booking_allowed(
        organizer_user_id,
        settings,
        meeting_type,
        limit_check.start_time,
        exclude_uid: limit_check.exclude_uid
      )
    else
      :ok
    end
  end

  defp fetch_meeting_type(nil, _organizer_user_id), do: nil

  defp fetch_meeting_type(meeting_type_id, organizer_user_id),
    do: MeetingTypes.get_meeting_type(meeting_type_id, organizer_user_id)

  # The buffer belongs to the schedule the meeting type is booked against, so it
  # is read through the same policy resolution the booking page used. A nil
  # meeting type resolves the organiser's default schedule, which is the right
  # answer for an ad-hoc block.
  defp get_buffer_minutes(nil, _meeting_type_id), do: 15

  defp get_buffer_minutes(organizer_user_id, meeting_type_id) do
    meeting_type = fetch_meeting_type(meeting_type_id, organizer_user_id)

    Policy.scheduling_config(organizer_user_id, meeting_type).buffer_minutes
  end

  defp compute_buffered_window(start_time, end_time, organizer_user_id, meeting_type_id) do
    buffer_minutes = get_buffer_minutes(organizer_user_id, meeting_type_id)

    {
      DateTime.add(start_time, -buffer_minutes, :minute),
      DateTime.add(end_time, buffer_minutes, :minute)
    }
  end

  defp create_meeting_in_transaction(attrs) do
    case MeetingQueries.create_meeting(attrs) do
      {:ok, meeting} -> meeting
      {:error, changeset} -> Repo.rollback({:validation_error, changeset})
    end
  end

  defp log_conflict(start_time, end_time, conflicting_count, meeting_uid \\ nil) do
    log_attrs = [
      requested_start: start_time,
      requested_end: end_time,
      conflicting_count: conflicting_count
    ]

    log_attrs = if meeting_uid, do: [{:meeting_uid, meeting_uid} | log_attrs], else: log_attrs

    Logger.info("Meeting time conflict detected during booking attempt", log_attrs)
  end

  defp handle_database_error(error, stacktrace, context) do
    :ok = ErrorTracking.report_error(error, stacktrace, context)
    {:error, :database_error}
  end

  defp execute_update_with_conflict_check(meeting, attrs, start_time, end_time, opts) do
    {buffered_start, buffered_end} =
      compute_buffered_window(
        start_time,
        end_time,
        meeting.organizer_user_id,
        meeting.meeting_type_id
      )

    limit_check =
      build_limit_check(
        meeting.organizer_user_id,
        start_time,
        meeting.meeting_type_id,
        meeting.uid,
        opts
      )

    Repo.transaction(fn ->
      with :ok <- enforce_booking_limits(limit_check),
           {:ok, :no_conflicts} <-
             MeetingConflictQueries.count_locked_conflicts(
               buffered_start,
               buffered_end,
               meeting.uid,
               meeting.organizer_user_id
             ) do
        update_meeting_in_transaction(meeting, attrs)
      else
        {:error, :booking_limit_reached} ->
          Repo.rollback(:booking_limit_reached)

        {:error, conflicting_count} ->
          log_update_conflict(meeting, start_time, end_time, conflicting_count)
          Repo.rollback(:time_conflict)
      end
    end)
  end

  defp update_meeting_in_transaction(meeting, attrs) do
    case MeetingQueries.update_meeting(meeting, attrs) do
      {:ok, updated_meeting} -> updated_meeting
      {:error, changeset} -> Repo.rollback({:validation_error, changeset})
    end
  end

  defp log_update_conflict(meeting, start_time, end_time, conflicting_count) do
    Logger.warning("Meeting update blocked due to time conflict",
      meeting_uid: meeting.uid,
      original_start: meeting.start_time,
      original_end: meeting.end_time,
      requested_start: start_time,
      requested_end: end_time,
      conflicting_count: conflicting_count
    )
  end
end
