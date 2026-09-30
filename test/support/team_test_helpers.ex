defmodule Tymeslot.TeamTestHelpers do
  @moduledoc """
  Builds teams whose members can actually be booked: each member has a
  bookable profile (`Tymeslot.AvailabilityTestHelpers.create_bookable_profile/1`)
  and an active calendar, which is what makes a team page public.
  """

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Teams

  @doc """
  Creates a team with `member_count` members, the first of whom owns it.

  `opts[:members]` gives per-member `create_bookable_profile/1` options, by
  position; `opts[:team]` further team attributes. Returns the team (reloaded
  with its members) and the members' `create_bookable_profile/1` results, the
  owner's first.
  """
  @spec create_team_with_members(pos_integer(), keyword()) :: %{team: map(), members: [map()]}
  def create_team_with_members(member_count, opts \\ []) do
    member_opts = Keyword.get(opts, :members, [])

    members =
      for index <- 0..(member_count - 1) do
        bookable = create_bookable_profile(Enum.at(member_opts, index, timezone: "Etc/UTC"))
        insert(:calendar_integration, user: bookable.user, is_active: true)
        bookable
      end

    [owner | others] = members

    team_attrs =
      Map.merge(
        %{
          name: "Team #{System.unique_integer([:positive])}",
          duration_minutes: 60
        },
        Map.new(Keyword.get(opts, :team, []))
      )

    {:ok, team} = Teams.create_team(owner.user.id, team_attrs)

    team =
      Enum.reduce(others, team, fn member, team ->
        {:ok, team} = Teams.add_member_by_email(team.id, owner.user.id, member.user.email)
        team
      end)

    %{team: team, members: members}
  end
end
