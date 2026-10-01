defmodule Tymeslot.TeamTestHelpers do
  @moduledoc """
  Builds teams whose members can actually be booked: each member has a
  bookable profile (`Tymeslot.AvailabilityTestHelpers.create_bookable_profile/1`)
  and an active calendar, which is what makes a team page public, and the team
  offers one meeting type.
  """

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Teams

  @doc """
  Creates a team with `member_count` members, the first of whom owns it, and
  one team meeting type.

  `opts[:members]` gives per-member `create_bookable_profile/1` options, by
  position; `opts[:team]` further team attributes; `opts[:meeting_type]`
  further attributes of the team's meeting type (60 minutes, slugged
  `team-call`, by default). Returns the team (reloaded with its members and
  meeting types), its meeting type, and the members'
  `create_bookable_profile/1` results, the owner's first.
  """
  @spec create_team_with_members(pos_integer(), keyword()) :: %{
          team: map(),
          meeting_type: map(),
          members: [map()]
        }
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
        %{name: "Team #{System.unique_integer([:positive])}"},
        Map.new(Keyword.get(opts, :team, []))
      )

    {:ok, team} = Teams.create_team(owner.user.id, team_attrs)

    for member <- others do
      {:ok, _team} = Teams.add_member_by_email(team.id, owner.user.id, member.user.email)
    end

    meeting_type =
      insert(
        :meeting_type,
        Keyword.merge(
          [
            user: owner.user,
            is_team_type: true,
            name: "Team call",
            slug: "team-call",
            duration_minutes: 60
          ],
          Keyword.get(opts, :meeting_type, [])
        )
      )

    {:ok, team} = Teams.offer_meeting_type(team.id, owner.user.id, meeting_type.id)

    %{team: team, meeting_type: meeting_type, members: members}
  end
end
