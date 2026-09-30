defmodule Tymeslot.Emails.EmailScheduler.TeamScheduler do
  @moduledoc """
  Schedules the email telling a user they were added to a team.
  """

  alias Ecto.Changeset
  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  require Logger

  # A day: re-adding someone within it (after removing them by mistake) does
  # not email them twice.
  @unique_period 86_400

  @doc "Schedules the \"you were added to a team\" email for `user_id`."
  @spec schedule_member_added(pos_integer(), pos_integer()) :: :ok
  def schedule_member_added(team_id, user_id) do
    args = %{"action" => "send_team_member_added", "team_id" => team_id, "user_id" => user_id}

    opts = [
      queue: :emails,
      priority: 2,
      unique: [
        period: @unique_period,
        fields: [:args, :queue],
        keys: [:action, :team_id, :user_id]
      ]
    ]

    case Oban.insert(EmailWorker.new(args, opts)) do
      {:ok, _job} ->
        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule team email job",
          action: args["action"],
          team_id: team_id,
          error: Helpers.format_insert_error(reason)
        )

        :ok
    end
  end
end
