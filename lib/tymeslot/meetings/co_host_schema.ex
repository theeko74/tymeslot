defmodule Tymeslot.Meetings.CoHostSchema do
  @moduledoc """
  A host who shares a meeting with its organiser.

  Written when a meeting is booked on a team page: every member of the team
  other than its owner (the organiser) becomes a co-host. The rows are a
  snapshot, so a member who later leaves the team stays on the meetings they
  were booked into. A co-host is busy for the meeting exactly as the organiser
  is: the availability engine, the submit's conflict check and the booking
  limits all read these rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Meetings.MeetingSchema

  @type t :: %__MODULE__{
          id: binary() | nil,
          meeting_id: binary() | nil,
          user_id: integer() | nil,
          confirmation_sent_at: DateTime.t() | nil,
          meeting: MeetingSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          user: UserSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "meeting_co_hosts" do
    field(:confirmation_sent_at, :utc_datetime)

    belongs_to(:meeting, MeetingSchema, type: :binary_id)
    belongs_to(:user, UserSchema, type: :id)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for stamping the confirmation email as sent."
  @spec confirmation_sent_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def confirmation_sent_changeset(co_host, sent_at) do
    cast(co_host, %{confirmation_sent_at: sent_at}, [:confirmation_sent_at])
  end
end
