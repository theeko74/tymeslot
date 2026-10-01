defmodule Tymeslot.Teams.TeamSchema do
  @moduledoc """
  A team: several hosts booked together on one public page, `/team/:slug`.

  The page offers only the times every member is free, and a booking made there
  is one meeting shared by all of them. What can be booked is the owner's team
  meeting types this team offers (`team_meeting_types`); see `Tymeslot.Teams`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Teams.TeamMemberSchema
  alias Tymeslot.Themes.Catalog
  alias Tymeslot.Validation.BookingText
  alias Tymeslot.Validation.Constraints

  @type t :: %__MODULE__{
          id: integer() | nil,
          owner_user_id: integer() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          description: String.t() | nil,
          booking_theme: String.t() | nil,
          booking_text_enabled: boolean(),
          booking_heading: String.t() | nil,
          booking_greeting: String.t() | nil,
          booking_instruction: String.t() | nil,
          logo: String.t() | nil,
          owner: UserSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          members: [TeamMemberSchema.t()] | Ecto.Association.NotLoaded.t(),
          meeting_types: [MeetingTypeSchema.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "teams" do
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    # The theme the team page renders. Nil borrows the owner's own.
    field(:booking_theme, :string)
    # The team page's own introductory wording, as on a personal page
    # (`Tymeslot.Validation.BookingText`). Switched off, the page shows the
    # team's name, its members and its description.
    field(:booking_text_enabled, :boolean, default: false)
    field(:booking_heading, :string)
    field(:booking_greeting, :string)
    field(:booking_instruction, :string)
    # File name of the uploaded logo shown in place of the owner's photo.
    field(:logo, :string)

    belongs_to(:owner, UserSchema, foreign_key: :owner_user_id)
    has_many(:members, TeamMemberSchema, foreign_key: :team_id)
    # The owner's team meeting types this team offers.
    many_to_many(:meeting_types, MeetingTypeSchema,
      join_through: Tymeslot.Teams.TeamMeetingTypeSchema,
      join_keys: [team_id: :id, meeting_type_id: :id]
    )

    timestamps(type: :utc_datetime)
  end

  # Same shape as a meeting type's custom slug: lowercase letters, digits and
  # single hyphens.
  @slug_format ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  # A literal segment under `/team/:slug/`, which a slug must not be mistaken for.
  @reserved_slugs ~w(thank-you)
  @slug_max_length 80

  @doc "The longest slug a team can have."
  @spec slug_max_length() :: pos_integer()
  def slug_max_length, do: @slug_max_length

  @doc "Changeset for creating or updating a team."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :slug, :description, :owner_user_id])
    |> update_change(:name, &String.trim/1)
    |> update_change(:slug, &normalize_slug/1)
    |> validate_required([:name, :slug, :owner_user_id])
    |> validate_length(:name, Constraints.name_length_opts())
    |> validate_length(:description, max: Constraints.description_max_length())
    |> validate_slug()
    |> unique_constraint(:slug, message: "is already taken")
    |> foreign_key_constraint(:owner_user_id)
  end

  @doc "Changeset for choosing the team page's theme (nil borrows the owner's)."
  @spec theme_changeset(t(), String.t() | nil) :: Ecto.Changeset.t()
  def theme_changeset(team, theme_id) do
    team
    |> change(booking_theme: theme_id)
    |> validate_change(:booking_theme, fn :booking_theme, theme ->
      if Catalog.valid_id?(theme), do: [], else: [booking_theme: "is not a valid theme"]
    end)
  end

  @doc "Changeset for the team page's introductory wording."
  @spec booking_text_changeset(t(), map()) :: Ecto.Changeset.t()
  def booking_text_changeset(team, attrs), do: BookingText.changeset(team, attrs)

  @doc "Changeset for setting or clearing the team's logo file name."
  @spec logo_changeset(t(), String.t() | nil) :: Ecto.Changeset.t()
  def logo_changeset(team, logo), do: change(team, logo: logo)

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
