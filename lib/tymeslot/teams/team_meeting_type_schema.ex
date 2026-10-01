defmodule Tymeslot.Teams.TeamMeetingTypeSchema do
  @moduledoc """
  Offers a team meeting type on a team's page.

  A team meeting type (`meeting_types.is_team_type`) belongs to the user who
  created it and can be offered by any number of that user's teams; one row
  here per team offering it. `position` orders the types on that team's page,
  each team keeping its own order.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Teams.TeamSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          team_id: integer() | nil,
          meeting_type_id: integer() | nil,
          position: integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "team_meeting_types" do
    belongs_to(:team, TeamSchema)
    belongs_to(:meeting_type, MeetingTypeSchema)
    field(:position, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for offering a meeting type on a team's page."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:team_id, :meeting_type_id, :position])
    |> validate_required([:team_id, :meeting_type_id])
    |> unique_constraint([:team_id, :meeting_type_id])
    |> foreign_key_constraint(:team_id)
    |> foreign_key_constraint(:meeting_type_id)
  end
end
