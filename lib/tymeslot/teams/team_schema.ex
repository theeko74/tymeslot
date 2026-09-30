defmodule Tymeslot.Teams.TeamSchema do
  @moduledoc """
  A team: several hosts booked together on one public page, `/team/:slug`.

  The page offers only the times every member is free, and a booking made there
  is one meeting shared by all of them. The team's booking settings (name,
  description, duration) are mirrored onto a `meeting_types` row owned by
  `owner_user_id` and flagged with this team's id; see `Tymeslot.Teams`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Teams.TeamMemberSchema
  alias Tymeslot.Validation.Constraints

  @type t :: %__MODULE__{
          id: integer() | nil,
          owner_user_id: integer() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          description: String.t() | nil,
          duration_minutes: integer() | nil,
          owner: UserSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          members: [TeamMemberSchema.t()] | Ecto.Association.NotLoaded.t(),
          meeting_type: MeetingTypeSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "teams" do
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:duration_minutes, :integer)

    belongs_to(:owner, UserSchema, foreign_key: :owner_user_id)
    has_many(:members, TeamMemberSchema, foreign_key: :team_id)
    has_one(:meeting_type, MeetingTypeSchema, foreign_key: :team_id)

    timestamps(type: :utc_datetime)
  end

  # Same shape as a meeting type's custom slug: lowercase letters, digits and
  # single hyphens.
  @slug_format ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  # Literal segments under `/team/:slug/`, which a slug must not be mistaken for.
  @reserved_slugs ~w(book thank-you)
  @slug_max_length 80

  @doc "The longest slug a team can have."
  @spec slug_max_length() :: pos_integer()
  def slug_max_length, do: @slug_max_length

  @doc "Changeset for creating or updating a team."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :slug, :description, :duration_minutes, :owner_user_id])
    |> update_change(:name, &String.trim/1)
    |> update_change(:slug, &normalize_slug/1)
    |> validate_required([:name, :slug, :duration_minutes, :owner_user_id])
    |> validate_length(:name, Constraints.name_length_opts())
    |> validate_length(:description, max: Constraints.description_max_length())
    |> validate_number(:duration_minutes, Constraints.duration_minutes_opts())
    |> validate_slug()
    |> unique_constraint(:slug, message: "is already taken")
    |> foreign_key_constraint(:owner_user_id)
  end

  defp normalize_slug(slug) when is_binary(slug), do: slug |> String.trim() |> String.downcase()
  defp normalize_slug(slug), do: slug

  defp validate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        changeset

      slug ->
        cond do
          String.length(slug) > @slug_max_length ->
            add_error(changeset, :slug, "is too long")

          slug in @reserved_slugs ->
            add_error(changeset, :slug, "is reserved")

          not Regex.match?(@slug_format, slug) ->
            add_error(changeset, :slug, "may only contain lowercase letters, numbers and hyphens")

          true ->
            changeset
        end
    end
  end
end
