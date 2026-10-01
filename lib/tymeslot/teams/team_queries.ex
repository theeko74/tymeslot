defmodule Tymeslot.Teams.TeamQueries do
  @moduledoc """
  Database queries for teams and their memberships. Pure data access; the
  rules live in `Tymeslot.Teams`.
  """

  import Ecto.Query

  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.Teams.{TeamMeetingTypeSchema, TeamMemberSchema, TeamSchema}

  @doc """
  What every reader of a team needs: the owner with their profile, the members
  with theirs, and the meeting types, in the team's own order, with the two
  integrations the booking pipeline reads off them.
  """
  @spec preloads() :: keyword()
  def preloads do
    [
      owner: :profile,
      members:
        {from(m in TeamMemberSchema, order_by: [asc: m.inserted_at, asc: m.id]), user: :profile},
      meeting_types: &meeting_types_by_team/1
    ]
  end

  # The order is the link's `position`, which a query preload cannot sort by
  # (Ecto joins the link table itself), hence a preload function: for a
  # many-to-many it returns `{team_id, meeting_type}` pairs, kept in order.
  defp meeting_types_by_team(team_ids) do
    rows =
      Repo.all(
        from(l in TeamMeetingTypeSchema,
          join: mt in MeetingTypeSchema,
          on: mt.id == l.meeting_type_id,
          where: l.team_id in ^team_ids,
          order_by: [asc: l.team_id, asc: l.position, asc: mt.sort_order, asc: mt.name],
          select: {l.team_id, mt}
        )
      )

    types =
      rows
      |> Enum.map(&elem(&1, 1))
      |> Repo.preload([:video_integration, :calendar_integration])

    Enum.zip_with(rows, types, fn {team_id, _type}, type -> {team_id, type} end)
  end

  @doc "Fetches a team by id with everything in `preloads/0`."
  @spec get(pos_integer()) :: TeamSchema.t() | nil
  def get(team_id) when is_integer(team_id) do
    TeamSchema
    |> Repo.get(team_id)
    |> Repo.preload(preloads())
  end

  def get(_team_id), do: nil

  @doc "Fetches a team by its public slug with everything in `preloads/0`."
  @spec get_by_slug(String.t()) :: TeamSchema.t() | nil
  def get_by_slug(slug) when is_binary(slug) do
    TeamSchema
    |> Repo.get_by(slug: String.downcase(slug))
    |> Repo.preload(preloads())
  end

  @doc "Fetches a team `user_id` belongs to, owner or member."
  @spec get_for_member(pos_integer(), pos_integer()) :: TeamSchema.t() | nil
  def get_for_member(team_id, user_id) do
    from(t in TeamSchema,
      join: m in TeamMemberSchema,
      on: m.team_id == t.id,
      where: t.id == ^team_id and m.user_id == ^user_id
    )
    |> Repo.one()
    |> Repo.preload(preloads())
  end

  @doc "Lists the teams `user_id` belongs to, owner or member, by name."
  @spec list_for_member(pos_integer()) :: [TeamSchema.t()]
  def list_for_member(user_id) do
    from(t in TeamSchema,
      join: m in TeamMemberSchema,
      on: m.team_id == t.id,
      where: m.user_id == ^user_id,
      order_by: [asc: t.name, asc: t.id]
    )
    |> Repo.all()
    |> Repo.preload(preloads())
  end

  @doc "Fetches a membership row."
  @spec get_membership(pos_integer(), pos_integer()) :: TeamMemberSchema.t() | nil
  def get_membership(team_id, user_id) do
    Repo.get_by(TeamMemberSchema, team_id: team_id, user_id: user_id)
  end

  @doc "Inserts a team."
  @spec insert_team(map()) :: {:ok, TeamSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert_team(attrs) do
    %TeamSchema{}
    |> TeamSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a team."
  @spec update_team(TeamSchema.t(), map()) :: {:ok, TeamSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_team(%TeamSchema{} = team, attrs) do
    team
    |> TeamSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc "Sets the team page's theme (nil borrows the owner's)."
  @spec update_booking_theme(TeamSchema.t(), String.t() | nil) ::
          {:ok, TeamSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_booking_theme(%TeamSchema{} = team, theme_id) do
    team
    |> TeamSchema.theme_changeset(theme_id)
    |> Repo.update()
  end

  @doc "Updates the team page's introductory wording."
  @spec update_booking_text(TeamSchema.t(), map()) ::
          {:ok, TeamSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_booking_text(%TeamSchema{} = team, attrs) do
    team
    |> TeamSchema.booking_text_changeset(attrs)
    |> Repo.update()
  end

  @doc "Sets or clears the team's logo file name."
  @spec update_logo(TeamSchema.t(), String.t() | nil) ::
          {:ok, TeamSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_logo(%TeamSchema{} = team, logo) do
    team
    |> TeamSchema.logo_changeset(logo)
    |> Repo.update()
  end

  @doc "Deletes a team, its memberships and its links to meeting types."
  @spec delete_team(TeamSchema.t()) :: {:ok, TeamSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_team(%TeamSchema{} = team), do: Repo.delete(team)

  @doc "Adds `user_id` to a team with `role`."
  @spec insert_member(pos_integer(), pos_integer(), TeamMemberSchema.role()) ::
          {:ok, TeamMemberSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert_member(team_id, user_id, role) do
    %TeamMemberSchema{}
    |> TeamMemberSchema.changeset(%{team_id: team_id, user_id: user_id, role: role})
    |> Repo.insert()
  end

  @doc """
  Offers a meeting type on a team, last in the team's order. Offering one
  already offered is a no-op.
  """
  @spec insert_team_meeting_type(pos_integer(), pos_integer()) :: :ok
  def insert_team_meeting_type(team_id, meeting_type_id) do
    last =
      Repo.one(
        from(l in TeamMeetingTypeSchema, where: l.team_id == ^team_id, select: max(l.position))
      )

    %TeamMeetingTypeSchema{}
    |> TeamMeetingTypeSchema.changeset(%{
      team_id: team_id,
      meeting_type_id: meeting_type_id,
      position: (last || -1) + 1
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:team_id, :meeting_type_id])

    :ok
  end

  @doc """
  Orders a team's meeting types as `meeting_type_ids` lists them. Ids the team
  does not offer are skipped; offered types left out keep their position.
  """
  @spec reorder_team_meeting_types(pos_integer(), [pos_integer()]) :: :ok
  def reorder_team_meeting_types(team_id, meeting_type_ids) do
    Repo.transaction(fn ->
      meeting_type_ids
      |> Enum.with_index()
      |> Enum.each(fn {meeting_type_id, position} ->
        Repo.update_all(
          from(l in TeamMeetingTypeSchema,
            where: l.team_id == ^team_id and l.meeting_type_id == ^meeting_type_id
          ),
          set: [position: position]
        )
      end)
    end)

    :ok
  end

  @doc "Stops offering a meeting type on a team."
  @spec delete_team_meeting_type(pos_integer(), pos_integer()) :: :ok
  def delete_team_meeting_type(team_id, meeting_type_id) do
    Repo.delete_all(
      from(l in TeamMeetingTypeSchema,
        where: l.team_id == ^team_id and l.meeting_type_id == ^meeting_type_id
      )
    )

    :ok
  end

  @doc "Deletes a membership row."
  @spec delete_member(TeamMemberSchema.t()) ::
          {:ok, TeamMemberSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_member(%TeamMemberSchema{} = member), do: Repo.delete(member)
end
