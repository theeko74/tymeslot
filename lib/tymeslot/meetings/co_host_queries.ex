defmodule Tymeslot.Meetings.CoHostQueries do
  @moduledoc """
  Database queries for the `meeting_co_hosts` table.
  """

  import Ecto.Query

  alias Ecto.UUID
  alias Tymeslot.Meetings.CoHostSchema, as: CoHost
  alias Tymeslot.Repo

  @doc """
  Records `user_ids` as co-hosts of `meeting_id`. Meant to run inside the
  booking transaction, so a failure rolls the meeting back with it.
  """
  @spec insert_all_for_meeting(binary(), [pos_integer()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def insert_all_for_meeting(_meeting_id, []), do: {:ok, 0}

  def insert_all_for_meeting(meeting_id, user_ids) when is_list(user_ids) do
    now = DateTime.utc_now(:second)

    rows =
      user_ids
      |> Enum.uniq()
      |> Enum.map(fn user_id ->
        %{
          id: UUID.generate(),
          meeting_id: meeting_id,
          user_id: user_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _rows} = Repo.insert_all(CoHost, rows)
    {:ok, count}
  rescue
    error in [Postgrex.Error, Ecto.ConstraintError] -> {:error, error}
  end

  @doc "Lists a meeting's co-hosts, each with its user and profile preloaded."
  @spec list_for_meeting(binary()) :: [CoHost.t()]
  def list_for_meeting(meeting_id) do
    CoHost
    |> where([c], c.meeting_id == ^meeting_id)
    |> order_by([c], asc: c.user_id)
    |> preload(user: :profile)
    |> Repo.all()
  end

  @doc "The user ids of a meeting's co-hosts."
  @spec user_ids_for_meeting(binary()) :: [pos_integer()]
  def user_ids_for_meeting(meeting_id) do
    CoHost
    |> where([c], c.meeting_id == ^meeting_id)
    |> select([c], c.user_id)
    |> Repo.all()
  end

  @doc """
  A query selecting the ids of every meeting `user_id` co-hosts.

  Meant to be used as `m.id in subquery(...)`, so callers that lock rows with
  `FOR UPDATE` keep a plain WHERE clause rather than an outer join.
  """
  @spec co_hosted_meeting_ids_query(pos_integer()) :: Ecto.Query.t()
  def co_hosted_meeting_ids_query(user_id) do
    from(c in CoHost, where: c.user_id == ^user_id, select: c.meeting_id)
  end

  @doc """
  Narrows a meetings query to the meetings `user_id` hosts: those they
  organise and those they co-host.

  This is what "the user is busy" means for every reader that decides it (the
  booking page's busy periods, the submit's locked conflict count and the
  booking-limit counts), so a team booking blocks every member everywhere they
  can be booked. The co-host side is a WHERE subquery, so `FOR UPDATE` stays
  legal on the result.
  """
  @spec where_hosted_by(Ecto.Queryable.t(), pos_integer()) :: Ecto.Query.t()
  def where_hosted_by(query, user_id) do
    co_hosted = co_hosted_meeting_ids_query(user_id)

    where(query, [m], m.organizer_user_id == ^user_id or m.id in subquery(co_hosted))
  end

  @doc "Stamps `confirmation_sent_at` on a co-host."
  @spec mark_confirmation_sent(CoHost.t(), DateTime.t()) ::
          {:ok, CoHost.t()} | {:error, Ecto.Changeset.t()}
  def mark_confirmation_sent(%CoHost{} = co_host, sent_at) do
    co_host
    |> CoHost.confirmation_sent_changeset(sent_at)
    |> Repo.update()
  end
end
