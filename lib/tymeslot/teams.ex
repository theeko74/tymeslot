defmodule Tymeslot.Teams do
  @moduledoc """
  Teams: several hosts booked together on one public page, `/team/:slug`.

  A team is created by its owner, who then adds other registered users by email.
  The team page offers only the times every member is free
  (`Tymeslot.Availability.TeamOffer`), and a booking made there is one meeting
  whose organiser is the owner and whose other members are co-hosts
  (`Tymeslot.Meetings.CoHostSchema`).

  ## The settings meeting type

  A team has one booking setting: a name, a description and a duration. It is
  mirrored onto a `meeting_types` row owned by the team's owner and flagged
  with `team_id`, so that the booking pipeline, which re-reads the meeting type
  by id and takes its rules from it, needs no second code path. The row is
  private, carries no availability schedule (each member is booked against
  their own default schedule), and is left out of every personal listing of
  the owner's meeting types. Deleting the team deletes it.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Features
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Repo
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Teams.{TeamQueries, TeamSchema}

  @type team :: TeamSchema.t()

  @type add_member_error ::
          :not_found | :unknown_account | :self | :already_member | Features.access_error()

  # --- Reading -------------------------------------------------------------

  @doc "Lists the teams `user_id` belongs to, as owner or member."
  @spec list_teams_for_user(pos_integer()) :: [team()]
  def list_teams_for_user(user_id), do: TeamQueries.list_for_member(user_id)

  @doc "Fetches a team `user_id` owns."
  @spec get_team_for_owner(pos_integer(), pos_integer()) :: {:ok, team()} | {:error, :not_found}
  def get_team_for_owner(team_id, user_id) do
    case TeamQueries.get(team_id) do
      %TeamSchema{owner_user_id: ^user_id} = team -> {:ok, team}
      _other -> {:error, :not_found}
    end
  end

  @doc "Fetches a team `user_id` belongs to, as owner or member."
  @spec get_team_for_member(pos_integer(), pos_integer()) ::
          {:ok, team()} | {:error, :not_found}
  def get_team_for_member(team_id, user_id) do
    case TeamQueries.get_for_member(team_id, user_id) do
      nil -> {:error, :not_found}
      team -> {:ok, team}
    end
  end

  @doc "Fetches a team by its public slug, for the team page."
  @spec get_team_by_slug(String.t()) :: team() | nil
  def get_team_by_slug(slug) when is_binary(slug), do: TeamQueries.get_by_slug(slug)
  def get_team_by_slug(_slug), do: nil

  @doc "Fetches a team by id, for the booking submit."
  @spec get_team_for_booking(pos_integer()) :: team() | nil
  def get_team_for_booking(team_id), do: TeamQueries.get(team_id)

  @doc "Whether `user_id` owns `team`."
  @spec owner?(team(), pos_integer() | nil) :: boolean()
  def owner?(%TeamSchema{owner_user_id: owner_id}, user_id), do: owner_id == user_id

  @doc """
  The profiles of every member, the owner's first. Each carries its `user`.

  A member without a profile (an account that never finished onboarding) is
  left out; `public_readiness/1` refuses such a team before this matters.
  """
  @spec member_profiles(team()) :: [map()]
  def member_profiles(%TeamSchema{members: members, owner_user_id: owner_id}) do
    members
    |> Enum.sort_by(&if(&1.user_id == owner_id, do: 0, else: 1))
    |> Enum.flat_map(fn
      %{user: %{profile: %{} = profile} = user} -> [%{profile | user: user}]
      _no_profile -> []
    end)
  end

  @doc "The profile of the team's owner, with its `user`."
  @spec owner_profile(team()) :: map() | nil
  def owner_profile(%TeamSchema{owner: %{profile: %{} = profile} = owner}),
    do: %{profile | user: owner}

  def owner_profile(_team), do: nil

  @doc """
  Every member's user id except the owner's: the co-hosts of a booking. None
  for a booking made outside a team (`nil`).
  """
  @spec co_host_user_ids(team() | nil) :: [pos_integer()]
  def co_host_user_ids(%TeamSchema{members: members, owner_user_id: owner_id}) do
    members
    |> Enum.map(& &1.user_id)
    |> Enum.reject(&(&1 == owner_id))
    |> Enum.sort()
  end

  def co_host_user_ids(nil), do: []

  @doc """
  Whether the team page can take bookings: every member needs a profile and a
  calendar the page can read, because a member whose calendar cannot be read
  would be offered times they are actually busy.
  """
  @spec public_readiness(team()) :: :ok | {:error, :team_member_not_ready}
  def public_readiness(%TeamSchema{members: members} = team) do
    profiles = member_profiles(team)

    if length(profiles) == length(members) and
         Enum.all?(profiles, &(LinkAccessPolicy.check_public_readiness(&1) == {:ok, :ready})) do
      :ok
    else
      {:error, :team_member_not_ready}
    end
  end

  @doc "Whether `user_id`'s calendar is ready for the team page, for the dashboard."
  @spec member_ready?(map() | nil) :: boolean()
  def member_ready?(%{} = profile),
    do: LinkAccessPolicy.check_public_readiness(profile) == {:ok, :ready}

  def member_ready?(_profile), do: false

  @doc "The booking theme of the owner of the team at `slug`, or nil."
  @spec owner_booking_theme(String.t()) :: String.t() | nil
  def owner_booking_theme(slug) do
    case get_team_by_slug(slug) do
      %TeamSchema{owner: %{profile: %{booking_theme: theme}}} when is_binary(theme) -> theme
      _other -> nil
    end
  end

  @doc "A team's public page path."
  @spec public_path(team() | String.t()) :: String.t()
  def public_path(%TeamSchema{slug: slug}), do: public_path(slug)
  def public_path(slug) when is_binary(slug), do: "/team/#{slug}"

  @doc "A slug derived from a team name."
  @spec slug_from_name(String.t() | nil) :: String.t()
  def slug_from_name(name) when is_binary(name) do
    name
    |> then(&Slugs.to_slug(%{name: &1}))
    |> String.slice(0, TeamSchema.slug_max_length())
    |> String.trim("-")
  end

  def slug_from_name(_name), do: ""

  # --- Writing -------------------------------------------------------------

  @doc """
  Creates a team owned by `owner_user_id`, its owner membership and its
  settings meeting type, in one transaction.

  `attrs` carries `name`, `duration_minutes`, and optionally `slug` (derived
  from the name when blank) and `description`.
  """
  @spec create_team(pos_integer(), map()) ::
          {:ok, team()} | {:error, :name_taken | Features.access_error() | Changeset.t()}
  def create_team(owner_user_id, attrs) do
    with :ok <- Features.check_access(owner_user_id, :teams) do
      attrs =
        attrs
        |> stringify()
        |> default_slug()
        |> Map.put("owner_user_id", owner_user_id)

      result =
        Repo.transaction(fn ->
          with {:ok, team} <- TeamQueries.insert_team(attrs),
               {:ok, _owner} <- TeamQueries.insert_member(team.id, owner_user_id, :owner),
               {:ok, _meeting_type} <- insert_meeting_type(team) do
            team.id
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      reload_result(result)
    end
  end

  @doc """
  Updates a team `owner_user_id` owns, and its settings meeting type with it.

  Every member's cached availability is dropped: a new duration moves every
  member's grid.
  """
  @spec update_team(pos_integer(), pos_integer(), map()) ::
          {:ok, team()} | {:error, :not_found | :name_taken | Changeset.t()}
  def update_team(team_id, owner_user_id, attrs) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id) do
      attrs = attrs |> stringify() |> Map.delete("owner_user_id")

      result =
        Repo.transaction(fn ->
          with {:ok, updated} <- TeamQueries.update_team(team, attrs),
               {:ok, _meeting_type} <- sync_meeting_type(team.meeting_type, updated) do
            updated.id
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      with {:ok, updated} <- reload_result(result) do
        invalidate_members(updated)
        {:ok, updated}
      end
    end
  end

  @doc """
  Deletes a team `owner_user_id` owns. Its memberships and settings meeting
  type go with it; meetings booked through it stay, no longer pointing at it.
  """
  @spec delete_team(pos_integer(), pos_integer()) :: :ok | {:error, :not_found}
  def delete_team(team_id, owner_user_id) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id),
         {:ok, _deleted} <- TeamQueries.delete_team(team) do
      :ok
    else
      {:error, %Changeset{}} -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Adds the registered user with `email` to a team `owner_user_id` owns, and
  emails them that they were added.
  """
  @spec add_member_by_email(pos_integer(), pos_integer(), String.t()) ::
          {:ok, team()} | {:error, add_member_error()}
  def add_member_by_email(team_id, owner_user_id, email) when is_binary(email) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id),
         :ok <- Features.check_access(owner_user_id, :teams),
         {:ok, user} <- find_account(email),
         :ok <- refuse_self(user, owner_user_id),
         {:ok, _member} <- TeamQueries.insert_member(team.id, user.id, :member) do
      EmailScheduler.schedule_team_member_added(team.id, user.id)
      {:ok, TeamQueries.get(team.id)}
    else
      {:error, %Changeset{}} -> {:error, :already_member}
      error -> error
    end
  end

  def add_member_by_email(_team_id, _owner_user_id, _email), do: {:error, :unknown_account}

  @doc "Removes a member from a team `owner_user_id` owns. The owner cannot be removed."
  @spec remove_member(pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, team()} | {:error, :not_found | :owner_cannot_leave}
  def remove_member(team_id, owner_user_id, user_id) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id),
         :ok <- delete_membership(team, user_id) do
      {:ok, TeamQueries.get(team.id)}
    end
  end

  @doc "Takes `user_id` out of a team they belong to. The owner cannot leave."
  @spec leave_team(pos_integer(), pos_integer()) ::
          :ok | {:error, :not_found | :owner_cannot_leave}
  def leave_team(team_id, user_id) do
    with {:ok, team} <- get_team_for_member(team_id, user_id) do
      delete_membership(team, user_id)
    end
  end

  @doc "The dashboard message for a team error."
  @spec error_message(atom()) :: String.t()
  def error_message(:unknown_account),
    do: dgettext("dashboard_teams", "No Tymeslot account uses this email address.")

  def error_message(:self), do: dgettext("dashboard_teams", "You are already in this team.")

  def error_message(:already_member),
    do: dgettext("dashboard_teams", "This person is already a member of the team.")

  def error_message(:owner_cannot_leave),
    do: dgettext("dashboard_teams", "The owner cannot leave the team. Delete it instead.")

  def error_message(:name_taken),
    do:
      dgettext(
        "dashboard_teams",
        "You already have a meeting type with this name. Choose another team name."
      )

  def error_message(:not_found), do: dgettext("dashboard_teams", "This team no longer exists.")

  def error_message(_other),
    do: dgettext("dashboard_teams", "Something went wrong. Please try again.")

  # --- Private -------------------------------------------------------------

  defp stringify(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp default_slug(attrs) do
    case attrs["slug"] do
      slug when is_binary(slug) and slug != "" -> attrs
      _blank -> Map.put(attrs, "slug", slug_from_name(attrs["name"]))
    end
  end

  defp insert_meeting_type(team) do
    team
    |> meeting_type_attrs()
    |> Map.merge(%{
      user_id: team.owner_user_id,
      team_id: team.id,
      is_private: true,
      is_active: true,
      allow_guests: false,
      payment_required: false,
      requires_approval: false,
      icon: "none"
    })
    |> MeetingTypeQueries.create_meeting_type()
    |> map_meeting_type_error()
  end

  defp sync_meeting_type(nil, team), do: insert_meeting_type(team)

  defp sync_meeting_type(meeting_type, team) do
    meeting_type
    |> MeetingTypeQueries.update_meeting_type(meeting_type_attrs(team))
    |> map_meeting_type_error()
  end

  defp meeting_type_attrs(team) do
    %{name: team.name, description: team.description, duration_minutes: team.duration_minutes}
  end

  # The settings row shares the owner's `(user_id, name)` unique index with
  # their own meeting types.
  defp map_meeting_type_error({:error, %Changeset{errors: errors} = changeset}) do
    name_taken? =
      Enum.any?(errors, fn {_field, {_message, opts}} ->
        opts[:constraint_name] == "meeting_types_user_id_name_index"
      end)

    if name_taken?, do: {:error, :name_taken}, else: {:error, changeset}
  end

  defp map_meeting_type_error(result), do: result

  defp reload_result({:ok, team_id}), do: {:ok, TeamQueries.get(team_id)}
  defp reload_result({:error, _reason} = error), do: error

  defp find_account(email) do
    case UserQueries.get_user_by_email(email) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:error, :unknown_account}
    end
  end

  defp refuse_self(%{id: id}, id), do: {:error, :self}
  defp refuse_self(_user, _owner_user_id), do: :ok

  defp delete_membership(%TeamSchema{owner_user_id: user_id}, user_id),
    do: {:error, :owner_cannot_leave}

  defp delete_membership(team, user_id) do
    case TeamQueries.get_membership(team.id, user_id) do
      nil ->
        {:error, :not_found}

      membership ->
        {:ok, _deleted} = TeamQueries.delete_member(membership)
        :ok
    end
  end

  defp invalidate_members(team) do
    Enum.each(team.members, &AvailabilityCache.invalidate_for_user(&1.user_id))
  end
end
