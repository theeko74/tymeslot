defmodule Tymeslot.Workers.EmailWorkerHandlers.TeamEmails do
  @moduledoc """
  Handles team email actions: telling a user they were added to a team.
  """

  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.Templates.TeamMemberAdded
  alias Tymeslot.Teams.TeamQueries
  alias Tymeslot.Utils.UrlBuilder

  # The team was deleted, or the user left or was removed, before the email
  # went out.
  @no_membership "team membership no longer exists"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason), do: reason == @no_membership

  @spec handle_member_added(%{String.t() => term()}) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_member_added(%{"team_id" => team_id, "user_id" => user_id}) do
    with %{} = team <- TeamQueries.get(team_id),
         %{user: %{} = user} <- Enum.find(team.members, &(&1.user_id == user_id)) do
      user
      |> TeamMemberAdded.render(team, team.owner, UrlBuilder.base_url() <> "/dashboard/teams")
      |> deliver()
    else
      _gone -> {:discard, @no_membership}
    end
  end

  defp deliver(email) do
    case Delivery.deliver(email) do
      {:ok, _result} -> :ok
      error -> error
    end
  end
end
