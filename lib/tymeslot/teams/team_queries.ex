defmodule Tymeslot.Teams.TeamQueries do
  @moduledoc """
  Database queries for teams and their memberships. Pure data access; the
  rules live in `Tymeslot.Teams`.
  """

  import Ecto.Query

  alias Tymeslot.Repo
  alias Tymeslot.Teams.{TeamMemberSchema, TeamSchema}

  @doc """
  What every reader of a team needs: the owner with their profile, the members
  with theirs, and the settings meeting type with the two integrations the
  booking pipeline reads off it.
  """
  @spec preloads() :: keyword()
  def preloads do
    [
      owner: :profile,
      members:
        {from(m in TeamMemberSchema, order_by: [asc: m.inserted_at, asc: m.id]), user: :profile},
      meeting_type: [:video_integration, :calendar_integration]
    ]
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

  @doc "Deletes a team, its memberships and its settings meeting type."
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

  @doc "Deletes a membership row."
  @spec delete_member(TeamMemberSchema.t()) ::
          {:ok, TeamMemberSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_member(%TeamMemberSchema{} = member), do: Repo.delete(member)
end
