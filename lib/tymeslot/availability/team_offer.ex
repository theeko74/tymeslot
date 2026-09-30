defmodule Tymeslot.Availability.TeamOffer do
  @moduledoc """
  The times a team page offers: those every member is free for.

  A team page asks the same two questions a personal page asks
  (`Tymeslot.Availability.Offer`), once per member, and keeps only the answers
  they all agree on. Each member is asked with their own profile and the
  team's settings meeting type. That type carries no availability schedule, so
  each member is weighed against their own default schedule, buffers, notice
  and booking limits, exactly as `Tymeslot.Bookings.Create` re-checks them for
  every member on submit.

  A member whose calendar cannot be read fails the whole answer rather than
  counting as free: offering a time they may be busy for is worse than showing
  the booker an error.

  Every answer is expressed in the booker's timezone on the same date and
  duration, so the per-member slot lists are directly comparable. The
  per-member month maps are cached by `Offer` under each member's own user id,
  so a member's calendar sync drops exactly the answers it affects.
  """

  alias Tymeslot.Availability.Offer

  @doc """
  One `Offer` request per member, each `base_request` with that member's
  profile. Rescheduling does not apply to team meetings.
  """
  @spec requests([map()], Offer.request()) :: [Offer.request()]
  def requests(member_profiles, base_request) do
    Enum.map(member_profiles, fn profile ->
      base_request
      |> Map.put(:profile, profile)
      |> Map.put(:reschedule_uid, nil)
    end)
  end

  @doc "The times free for every member on `date_string` (ISO 8601)."
  @spec slots_for_date([Offer.request()], String.t(), String.t() | integer() | nil) ::
          {:ok, [String.t()]} | {:error, any()}
  def slots_for_date([], _date_string, _duration), do: {:ok, []}

  def slots_for_date(requests, date_string, duration) do
    with {:ok, [first | rest]} <-
           collect(requests, &Offer.slots_for_date(&1, date_string, duration)) do
      others = Enum.map(rest, &MapSet.new/1)
      {:ok, Enum.filter(first, fn slot -> Enum.all?(others, &MapSet.member?(&1, slot)) end)}
    end
  end

  @doc """
  Which days in `start_date..end_date` have at least one time every member is
  free for.

  A day is kept only when every member has a free time on it, which is
  necessary but not sufficient: two members free at different hours of the
  same day both mark it. The day's slot list (`slots_for_date/3`) is the exact
  answer, and the calendar only uses this map to grey out days.
  """
  @spec days_in_range([Offer.request()], Date.t(), Date.t(), pos_integer() | nil) ::
          {:ok, %{String.t() => boolean()}} | {:error, any()}
  def days_in_range([], _start_date, _end_date, _duration_minutes), do: {:ok, %{}}

  def days_in_range(requests, start_date, end_date, duration_minutes) do
    with {:ok, [first | rest]} <-
           collect(requests, &Offer.days_in_range(&1, start_date, end_date, duration_minutes)) do
      {:ok, Enum.reduce(rest, first, &open_on_both/2)}
    end
  end

  # A day stays open only while every member's map has it open.
  defp open_on_both(map, acc) do
    Map.new(acc, fn {day, open?} -> {day, open? and Map.get(map, day, false)} end)
  end

  # Each member's answer, in member order, or the first error met.
  defp collect(requests, fetch) do
    result =
      Enum.reduce_while(requests, {:ok, []}, fn request, {:ok, acc} ->
        case fetch.(request) do
          {:ok, answer} -> {:cont, {:ok, [answer | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, answers} <- result, do: {:ok, Enum.reverse(answers)}
  end
end
