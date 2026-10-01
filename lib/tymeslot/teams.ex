defmodule Tymeslot.Teams do
  @moduledoc """
  Teams: several hosts booked together on one public page, `/team/:slug`.

  A team is created by its owner, who then adds other registered users by email.
  The team page offers only the times every member is free
  (`Tymeslot.Availability.TeamOffer`), and a booking made there is one meeting
  whose organiser is the owner and whose other members are co-hosts
  (`Tymeslot.Meetings.CoHostSchema`).

  ## Team meeting types

  What a team page offers is team meeting types, configured like the owner's
  own (duration, video, locations, questions, reminders...). They are
  `meeting_types` rows flagged `is_team_type`, owned by the user who created
  them, so that the booking pipeline, which re-reads the meeting type by id and
  takes its rules from it, needs no second code path. They are generic: one is
  created once and offered by any of its owner's teams (`team_meeting_types`).
  They are named and slugged among their owner's team types, and left out of
  every personal listing of the owner's meeting types.

  Two settings a personal type has do not apply (`MeetingTypeSchema` enforces
  both): a team type names no availability schedule, since each member is
  booked against their own default one, and it cannot be paid.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Features
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Repo
  alias Tymeslot.Scheduling.LinkAccessPolicy
  alias Tymeslot.Teams.{TeamLogos, TeamQueries, TeamSchema}
  alias Tymeslot.ThemeCustomizations

  @type team :: TeamSchema.t()

  @type add_member_error ::
          :not_found | :unknown_account | :self | :already_member | Features.access_error()

  # --- Reading -------------------------------------------------------------

  @doc "Lists the teams `user_id` belongs to, as owner or member."
  @spec list_teams_for_user(pos_integer()) :: [team()]
  def list_teams_for_user(user_id), do: TeamQueries.list_for_member(user_id)

  @doc "Lists the teams `user_id` owns, the ones whose meeting types they manage."
  @spec list_owned_teams(pos_integer()) :: [team()]
  def list_owned_teams(user_id) do
    user_id
    |> list_teams_for_user()
    |> Enum.filter(&owner?(&1, user_id))
  end

  @doc """
  The meeting types a team page lists: active and not private. A private one
  is still bookable through its direct link (`/team/:slug/:type`).
  """
  @spec public_meeting_types(team()) :: [MeetingTypeSchema.t()]
  def public_meeting_types(%TeamSchema{meeting_types: meeting_types}) do
    Enum.filter(meeting_types, &(&1.is_active and not &1.is_private))
  end

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

  @doc """
  The theme the team page at `slug` renders: the team's own, else its owner's,
  or nil for an unknown team.
  """
  @spec page_theme_by_slug(String.t()) :: String.t() | nil
  def page_theme_by_slug(slug) do
    case get_team_by_slug(slug) do
      %TeamSchema{} = team -> booking_theme(team)
      nil -> nil
    end
  end

  @doc "The theme a team page renders: the team's own, else its owner's."
  @spec booking_theme(team()) :: String.t() | nil
  def booking_theme(%TeamSchema{booking_theme: theme}) when is_binary(theme), do: theme
  def booking_theme(%TeamSchema{owner: %{profile: %{booking_theme: theme}}}), do: theme
  def booking_theme(_team), do: nil

  @doc """
  Whose theme customisation a team page renders and edits
  (`Tymeslot.ThemeCustomizations.Owner`): the team's own, stored with its
  owner's profile id. Nil when the owner has no profile.
  """
  @spec customization_owner(team()) :: {:team, pos_integer(), pos_integer()} | nil
  def customization_owner(%TeamSchema{id: team_id, owner: %{profile: %{id: profile_id}}}),
    do: {:team, team_id, profile_id}

  def customization_owner(_team), do: nil

  @doc """
  Sets the team page's theme, for a team `owner_user_id` owns. Nil makes the
  page wear its owner's again.
  """
  @spec update_booking_theme(pos_integer(), pos_integer(), String.t() | nil) ::
          {:ok, team()} | {:error, :not_found | Changeset.t()}
  def update_booking_theme(team_id, owner_user_id, theme_id) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id),
         {:ok, _updated} <- TeamQueries.update_booking_theme(team, theme_id) do
      {:ok, TeamQueries.get(team.id)}
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
  Creates a team owned by `owner_user_id` and its owner membership, in one
  transaction.

  `attrs` carries `name`, and optionally `slug` (derived from the name when
  blank) and `description`. The team offers nothing until team meeting
  types are offered on it (`offer_meeting_type/3`).
  """
  @spec create_team(pos_integer(), map()) ::
          {:ok, team()} | {:error, Features.access_error() | Changeset.t()}
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
               {:ok, _owner} <- TeamQueries.insert_member(team.id, owner_user_id, :owner) do
            team.id
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      reload_result(result)
    end
  end

  @doc "Updates a team `owner_user_id` owns."
  @spec update_team(pos_integer(), pos_integer(), map()) ::
          {:ok, team()} | {:error, :not_found | Changeset.t()}
  def update_team(team_id, owner_user_id, attrs) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id),
         {:ok, updated} <-
           TeamQueries.update_team(team, attrs |> stringify() |> Map.delete("owner_user_id")) do
      {:ok, TeamQueries.get(updated.id)}
    end
  end

  @doc """
  Updates the team page's introductory wording (`booking_text_enabled` and the
  three lines), for a team `owner_user_id` owns.
  """
  @spec update_booking_text(pos_integer(), pos_integer(), map()) ::
          {:ok, team()} | {:error, :not_found | Changeset.t()}
  def update_booking_text(team_id, owner_user_id, attrs) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id),
         {:ok, updated} <- TeamQueries.update_booking_text(team, attrs) do
      {:ok, TeamQueries.get(updated.id)}
    end
  end

  @doc "The public path of the team's logo, or nil when it has none."
  @spec logo_path(team() | map() | nil) :: String.t() | nil
  defdelegate logo_path(team), to: TeamLogos

  @doc """
  Stores an uploaded logo for a team `owner_user_id` owns, replacing any
  earlier one. `entry` carries the temporary `path`, the `client_name` and the
  `client_size` of the upload.
  """
  @spec store_logo(pos_integer(), pos_integer(), TeamLogos.uploaded_entry()) ::
          {:ok, team()} | {:error, term()}
  def store_logo(team_id, owner_user_id, entry) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id),
         {:ok, updated} <- TeamLogos.store(team, entry) do
      {:ok, TeamQueries.get(updated.id)}
    end
  end

  @doc "Removes the logo of a team `owner_user_id` owns."
  @spec remove_logo(pos_integer(), pos_integer()) ::
          {:ok, team()} | {:error, :not_found | Changeset.t()}
  def remove_logo(team_id, owner_user_id) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id),
         {:ok, updated} <- TeamLogos.remove(team) do
      {:ok, TeamQueries.get(updated.id)}
    end
  end

  @doc """
  Creates a team meeting type for `user_id`, from the meeting type form's
  params, exactly as a personal one is created
  (`Tymeslot.MeetingTypes.create_meeting_type_from_form/4`). It is offered by
  none of their teams until `offer_meeting_type/3` adds it to one.
  """
  @spec create_team_meeting_type(pos_integer(), map(), map()) ::
          {:ok, MeetingTypeSchema.t()} | {:error, atom() | Changeset.t()}
  def create_team_meeting_type(user_id, form_params, ui_state) do
    with :ok <- Features.check_access(user_id, :teams) do
      MeetingTypes.create_meeting_type_from_form(user_id, form_params, ui_state, team_type: true)
    end
  end

  @doc """
  Offers one of `owner_user_id`'s team meeting types on a team they own.
  Offering one already offered is a no-op.
  """
  @spec offer_meeting_type(pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, team()} | {:error, :not_found}
  def offer_meeting_type(team_id, owner_user_id, meeting_type_id) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id),
         {:ok, meeting_type} <- owned_team_type(meeting_type_id, owner_user_id) do
      TeamQueries.insert_team_meeting_type(team.id, meeting_type.id)
      {:ok, TeamQueries.get(team.id)}
    end
  end

  @doc """
  Orders the meeting types of a team `owner_user_id` owns, as
  `meeting_type_ids` lists them. Each team keeps its own order, whatever the
  order of the same types elsewhere.
  """
  @spec reorder_meeting_types(pos_integer(), pos_integer(), [pos_integer()]) ::
          {:ok, team()} | {:error, :not_found}
  def reorder_meeting_types(team_id, owner_user_id, meeting_type_ids) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id) do
      TeamQueries.reorder_team_meeting_types(team.id, meeting_type_ids)
      {:ok, TeamQueries.get(team.id)}
    end
  end

  @doc "Stops offering a meeting type on a team `owner_user_id` owns."
  @spec withdraw_meeting_type(pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, team()} | {:error, :not_found}
  def withdraw_meeting_type(team_id, owner_user_id, meeting_type_id) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id) do
      TeamQueries.delete_team_meeting_type(team.id, meeting_type_id)
      {:ok, TeamQueries.get(team.id)}
    end
  end

  @doc "Whether `team` offers `meeting_type`."
  @spec offers?(team(), map() | nil) :: boolean()
  def offers?(%TeamSchema{meeting_types: meeting_types}, %{id: id}),
    do: Enum.any?(meeting_types, &(&1.id == id))

  def offers?(_team, _meeting_type), do: false

  defp owned_team_type(meeting_type_id, user_id) do
    case MeetingTypes.get_meeting_type(meeting_type_id, user_id) do
      %{is_team_type: true} = meeting_type -> {:ok, meeting_type}
      _other -> {:error, :not_found}
    end
  end

  @doc """
  Deletes a team `owner_user_id` owns. Its memberships and meeting types go
  with it; meetings booked through it stay, no longer pointing at it.
  """
  @spec delete_team(pos_integer(), pos_integer()) :: :ok | {:error, :not_found}
  def delete_team(team_id, owner_user_id) do
    with {:ok, team} <- get_team_for_owner(team_id, owner_user_id),
         {:ok, _deleted} <- TeamQueries.delete_team(team) do
      # Its theme customisations went with it; their uploaded files did not,
      # nor did its logo.
      ThemeCustomizations.delete_team_files(team.id)
      TeamLogos.delete_all_files(team.id)
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
end
