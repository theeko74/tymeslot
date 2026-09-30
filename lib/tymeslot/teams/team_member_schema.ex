defmodule Tymeslot.Teams.TeamMemberSchema do
  @moduledoc """
  A user's membership of a team. The team's owner holds the one `:owner` row;
  everyone else added to the team is a `:member`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Teams.TeamSchema

  @type role :: :owner | :member

  @type t :: %__MODULE__{
          id: integer() | nil,
          team_id: integer() | nil,
          user_id: integer() | nil,
          role: role() | nil,
          team: TeamSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          user: UserSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "team_members" do
    field(:role, Ecto.Enum, values: [:owner, :member], default: :member)

    belongs_to(:team, TeamSchema)
    belongs_to(:user, UserSchema)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for adding a user to a team."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:team_id, :user_id, :role])
    |> validate_required([:team_id, :user_id, :role])
    |> unique_constraint([:team_id, :user_id],
      name: :team_members_team_id_user_id_index,
      message: "is already a member"
    )
    |> foreign_key_constraint(:team_id)
    |> foreign_key_constraint(:user_id)
  end
end
